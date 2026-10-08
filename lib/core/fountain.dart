import 'dart:math' as math;
import 'dart:typed_data';

const _mask = 0xFFFFFFFF;

/// 32-bit multiply that gives identical results on the Dart VM and on the web
/// (where ints are doubles and lose precision above 2^53).
int _mul32(int a, int b) {
  final lo = a * (b & 0xFFFF);
  final hi = ((a * (b >> 16)) & 0xFFFF) << 16;
  return (lo + hi) & _mask;
}

int _fmix32(int h) {
  h ^= h >> 16;
  h = _mul32(h, 0x85EBCA6B);
  h ^= h >> 13;
  h = _mul32(h, 0xC2B2AE35);
  h ^= h >> 16;
  return h & _mask;
}

/// Deterministic, platform-independent PRNG. Sender and receiver derive the
/// same block choices from (fileId, seq) so no index list travels on air.
class StreamRng {
  int _state;
  StreamRng(int fileId, int seq)
      : _state = _fmix32((fileId ^ _fmix32(seq & _mask)) & _mask);

  int next() {
    _state = (_state + 0x9E3779B9) & _mask;
    return _fmix32(_state);
  }

  int nextInt(int max) => next() % max;
}

/// Indices of the source blocks XOR-ed into packet [seq].
/// The first K packets are systematic (one plain block each), so a receiver
/// that sees the whole first pass needs no decoding at all.
List<int> blockIndices(int fileId, int k, int seq, int degree) {
  if (seq < k) return [seq];
  final d = math.min(degree, k);
  final rng = StreamRng(fileId, seq);
  if (d * 2 > k) {
    // Dense: partial Fisher-Yates over all indices.
    final all = List<int>.generate(k, (i) => i);
    for (var i = 0; i < d; i++) {
      final j = i + rng.nextInt(k - i);
      final t = all[i];
      all[i] = all[j];
      all[j] = t;
    }
    return all.sublist(0, d);
  }
  final picked = <int>{};
  while (picked.length < d) {
    picked.add(rng.nextInt(k));
  }
  return picked.toList();
}

/// Robust soliton degree distribution (Luby, 2002). Only the sender samples
/// it; the chosen degree is sent in the packet header so float differences
/// between platforms can never desynchronise the two sides.
class RobustSoliton {
  final List<double> _cdf;
  final math.Random _random;

  RobustSoliton(int k, {double c = 0.1, double delta = 0.5, math.Random? random})
      : _cdf = _build(k, c, delta),
        _random = random ?? math.Random();

  static List<double> _build(int k, double c, double delta) {
    if (k <= 1) return [1.0];
    final r = c * math.log(k / delta) * math.sqrt(k);
    final spike = math.max(1, math.min(k, (k / r).floor()));
    final p = List<double>.filled(k + 1, 0);
    p[1] = 1 / k;
    for (var d = 2; d <= k; d++) {
      p[d] = 1 / (d * (d - 1));
    }
    for (var d = 1; d < spike; d++) {
      p[d] += r / (d * k);
    }
    p[spike] += r * math.log(r / delta) / k;
    final total = p.reduce((a, b) => a + b);
    final cdf = List<double>.filled(k, 0);
    var acc = 0.0;
    for (var d = 1; d <= k; d++) {
      acc += p[d] / total;
      cdf[d - 1] = acc;
    }
    return cdf;
  }

  int sample() {
    final u = _random.nextDouble();
    var lo = 0, hi = _cdf.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cdf[mid] < u) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo + 1;
  }
}

void xorInto(Uint8List dst, Uint8List src) {
  if (dst.length % 4 == 0 &&
      dst.offsetInBytes % 4 == 0 &&
      src.offsetInBytes % 4 == 0) {
    final d = dst.buffer.asUint32List(dst.offsetInBytes, dst.length >> 2);
    final s = src.buffer.asUint32List(src.offsetInBytes, dst.length >> 2);
    for (var i = 0; i < d.length; i++) {
      d[i] ^= s[i];
    }
    return;
  }
  for (var i = 0; i < dst.length; i++) {
    dst[i] ^= src[i];
  }
}

class _Equation {
  final Set<int> indices;
  final Uint8List data;
  _Equation(this.indices, this.data);
}

/// LT decoder: fast peeling (belief propagation), plus a Gaussian
/// elimination rescue when peeling stalls even though enough equations have
/// arrived. The rescue cuts the extra frames needed for small files roughly
/// in half.
class FountainDecoder {
  /// Gaussian elimination is only attempted below this many unknown blocks.
  static const gaussLimit = 1200;
  final int k;
  final int blockSize;
  final List<Uint8List?> blocks;
  final Map<int, List<_Equation>> _waiting = {};
  final Set<int> _seenSeq = {};
  final Set<_Equation> _live = {};
  int _eqAdded = 0;
  int _gaussMark = 0;
  int solved = 0;

  FountainDecoder(this.k, this.blockSize) : blocks = List.filled(k, null);

  bool get isComplete => solved == k;
  int get pendingEquations => _live.length;
  int get uniquePackets => _seenSeq.length;

  /// Feeds one packet. Returns true when it was new (not a duplicate).
  bool add(int seq, List<int> indices, Uint8List data) {
    if (isComplete || !_seenSeq.add(seq)) return false;
    final payload = Uint8List.fromList(data);
    final remaining = <int>{};
    for (final i in indices) {
      final b = blocks[i];
      if (b != null) {
        xorInto(payload, b);
      } else {
        remaining.add(i);
      }
    }
    if (remaining.isEmpty) return true;
    if (remaining.length == 1) {
      _solve(remaining.first, payload);
    } else {
      final eq = _Equation(remaining, payload);
      _live.add(eq);
      _eqAdded++;
      for (final i in remaining) {
        (_waiting[i] ??= []).add(eq);
      }
    }
    _maybeGauss();
    return true;
  }

  void _maybeGauss() {
    final unknown = k - solved;
    if (unknown == 0 || unknown > gaussLimit || _live.length < unknown) return;
    // Throttle: rank checks cost O(n^3 / 32); retry only after fresh rows.
    if (_eqAdded < _gaussMark + math.max(1, unknown ~/ 64)) return;
    _gaussMark = _eqAdded;
    _gauss();
  }

  void _gauss() {
    final cols = <int, int>{};
    final colToBlock = <int>[];
    for (var i = 0; i < k; i++) {
      if (blocks[i] == null) {
        cols[i] = colToBlock.length;
        colToBlock.add(i);
      }
    }
    final n = colToBlock.length;
    final words = (n + 31) >> 5;
    final eqs = _live.toList();
    List<Uint32List> buildRows() => [
          for (final eq in eqs)
            () {
              final row = Uint32List(words);
              for (final i in eq.indices) {
                final c = cols[i]!;
                row[c >> 5] |= 1 << (c & 31);
              }
              return row;
            }()
        ];

    // Pass 1: coefficients only, to find out if the system is solvable.
    if (_eliminate(buildRows(), null, n) == null) return;
    // Pass 2: same elimination, now carrying the block data along.
    final data = [for (final eq in eqs) Uint8List.fromList(eq.data)];
    final pivots = _eliminate(buildRows(), data, n)!;
    for (var c = 0; c < n; c++) {
      blocks[colToBlock[c]] = data[pivots[c]];
    }
    solved = k;
    _live.clear();
    _waiting.clear();
  }

  /// Reduces [rows] to reduced row-echelon form. Returns, per column, the
  /// row holding its pivot, or null when the rank is below [n].
  static List<int>? _eliminate(List<Uint32List> rows, List<Uint8List>? data, int n) {
    final pivotRow = List<int>.filled(n, -1);
    final used = List<bool>.filled(rows.length, false);
    for (var c = 0; c < n; c++) {
      final w = c >> 5, bit = 1 << (c & 31);
      var p = -1;
      for (var r = 0; r < rows.length; r++) {
        if (!used[r] && rows[r][w] & bit != 0) {
          p = r;
          break;
        }
      }
      if (p < 0) return null;
      used[p] = true;
      pivotRow[c] = p;
      final pr = rows[p];
      for (var r = 0; r < rows.length; r++) {
        if (r == p || rows[r][w] & bit == 0) continue;
        final row = rows[r];
        for (var i = w; i < row.length; i++) {
          row[i] ^= pr[i];
        }
        if (data != null) xorInto(data[r], data[p]);
      }
    }
    return pivotRow;
  }

  void _solve(int index, Uint8List value) {
    final queue = <MapEntry<int, Uint8List>>[MapEntry(index, value)];
    while (queue.isNotEmpty) {
      final e = queue.removeLast();
      if (blocks[e.key] != null) continue;
      blocks[e.key] = e.value;
      solved++;
      final eqs = _waiting.remove(e.key);
      if (eqs == null) continue;
      for (final eq in eqs) {
        if (!eq.indices.remove(e.key)) continue;
        xorInto(eq.data, e.value);
        if (eq.indices.length == 1) {
          final last = eq.indices.first;
          eq.indices.clear();
          _live.remove(eq);
          _waiting[last]?.remove(eq);
          queue.add(MapEntry(last, eq.data));
        }
      }
    }
  }

  Uint8List assemble() {
    final out = Uint8List(k * blockSize);
    for (var i = 0; i < k; i++) {
      out.setRange(i * blockSize, (i + 1) * blockSize, blocks[i]!);
    }
    return out;
  }
}
