import 'dart:math' as math;
import 'dart:typed_data';

/// A small acoustic modem: 16-tone FSK, 4 bits per 40 ms symbol
/// (100 bit/s, 12.5 B/s raw), in the 1.6–3.1 kHz band every phone speaker
/// and microphone handles well.
///
/// Frame on air:
///   preamble (6 symbols) | length (1 byte) | payload | CRC-16 (2 bytes)
/// Each byte is two symbols, high nibble first.
///
/// Tones sit 100 Hz apart, a multiple of 1 / symbol time (25 Hz), so each
/// symbol's tone is orthogonal to the others over a symbol window and the
/// receiver can measure all 16 with Goertzel filters.
class SoundModem {
  static const symbolSeconds = 0.04;
  static const baseHz = 1600.0;
  static const stepHz = 100.0;
  static const tones = 16;
  static const maxPayload = 64;
  static const preamble = [0, 15, 0, 15, 5, 10];

  final int sampleRate;
  final int symbolSamples;

  SoundModem({this.sampleRate = 48000})
      : symbolSamples = (sampleRate * symbolSeconds).round();

  double toneHz(int t) => baseHz + t * stepHz;

  /// Symbols (0..15) for one frame carrying [payload].
  static List<int> frameSymbols(List<int> payload) {
    if (payload.length > maxPayload) {
      throw ArgumentError('Sound frames carry at most $maxPayload bytes');
    }
    final bytes = [payload.length, ...payload];
    final crc = crc16(bytes);
    bytes..add(crc >> 8)..add(crc & 0xFF);
    return [
      ...preamble,
      for (final b in bytes) ...[b >> 4, b & 0xF],
    ];
  }

  /// Number of symbols on air for a payload of [length] bytes.
  static int frameLength(int length) => preamble.length + 2 * (length + 3);

  /// Audio samples (-0.8..0.8) for one frame, with short silences around it.
  Float32List modulate(List<int> payload, {double gap = 0.1}) {
    final symbols = frameSymbols(payload);
    final pad = (sampleRate * gap).round();
    final out = Float32List(pad * 2 + symbols.length * symbolSamples);
    // Raised-cosine edges stop clicks between symbols; the phase is kept
    // continuous so tone changes stay quiet.
    final ramp = symbolSamples ~/ 10;
    var phase = 0.0;
    for (var s = 0; s < symbols.length; s++) {
      final w = 2 * math.pi * toneHz(symbols[s]) / sampleRate;
      final at = pad + s * symbolSamples;
      for (var i = 0; i < symbolSamples; i++) {
        var a = 0.8;
        if (i < ramp) {
          a *= 0.5 - 0.5 * math.cos(math.pi * i / ramp);
        } else if (i >= symbolSamples - ramp) {
          a *= 0.5 - 0.5 * math.cos(math.pi * (symbolSamples - i) / ramp);
        }
        out[at + i] = a * math.sin(phase);
        phase += w;
      }
      phase %= 2 * math.pi;
    }
    return out;
  }

  /// WAV (16-bit mono PCM) file bytes for [samples], for players that take
  /// a file rather than raw samples.
  Uint8List wav(Float32List samples) {
    final data = samples.length * 2;
    final b = ByteData(44 + data);
    void str(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + data, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, data, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      b.setInt16(44 + i * 2, v, Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

/// CRC-16/CCITT-FALSE.
int crc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = crc & 0x8000 != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

class _Hop {
  final int tone;
  final double share; // energy of the strongest tone / energy of all tones
  _Hop(this.tone, this.share);
}

/// Streaming demodulator. Feed it microphone samples in any chunk size; it
/// returns the payload of every frame whose CRC checks out.
///
/// The receiver doesn't know where symbols start, so it measures the tones
/// every quarter symbol ("hop") and looks for the preamble at each hop. Of
/// the neighbouring hops that match, it reads the frame at the one where
/// tones are cleanest (best aligned with the symbol boundaries).
class SoundDecoder {
  final SoundModem modem;
  final int hop;
  final List<double> _samples = [];
  final List<_Hop> _hops = [];
  late final List<double> _coeff;
  int _scan = 0; // next hop to test for a preamble

  /// Frames rejected by the CRC (for diagnostics).
  int badFrames = 0;

  SoundDecoder(this.modem) : hop = modem.symbolSamples ~/ 4 {
    _coeff = [
      for (var t = 0; t < SoundModem.tones; t++)
        2 * math.cos(2 * math.pi * modem.toneHz(t) / modem.sampleRate),
    ];
  }

  List<List<int>> add(List<double> samples) {
    _samples.addAll(samples);
    final n = modem.symbolSamples;
    while ((_hops.length) * hop + n <= _samples.length) {
      _hops.add(_measure(_hops.length * hop));
    }
    final found = <List<int>>[];
    final pre = SoundModem.preamble;
    final step = 4; // hops per symbol
    while (_scan + step * pre.length <= _hops.length) {
      if (!_preambleAt(_scan)) {
        _scan++;
        continue;
      }
      // Best-aligned of this hop and the next one.
      var start = _scan;
      if (_preambleAt(_scan + 1) &&
          _alignment(_scan + 1) > _alignment(_scan)) {
        start = _scan + 1;
      }
      final body = start + step * pre.length;
      if (body + step * 2 > _hops.length) break; // wait for the length byte
      final len = _byteAt(body);
      if (len > SoundModem.maxPayload) {
        _scan++;
        continue;
      }
      final end = body + step * 2 * (len + 3);
      if (end > _hops.length) break; // wait for the rest of the frame
      final bytes = [for (var i = 0; i < len + 3; i++) _byteAt(body + i * 8)];
      final crc = (bytes[len + 1] << 8) | bytes[len + 2];
      if (crc16(bytes.sublist(0, len + 1)) == crc) {
        found.add(bytes.sublist(1, len + 1));
        _scan = end;
      } else {
        badFrames++;
        _scan++;
      }
    }
    _trim();
    return found;
  }

  bool _preambleAt(int h) {
    final pre = SoundModem.preamble;
    if (h + 4 * pre.length > _hops.length) return false;
    for (var j = 0; j < pre.length; j++) {
      final m = _hops[h + 4 * j];
      if (m.tone != pre[j] || m.share < 0.4) return false;
    }
    return true;
  }

  double _alignment(int h) {
    var s = 0.0;
    for (var j = 0; j < SoundModem.preamble.length; j++) {
      s += _hops[h + 4 * j].share;
    }
    return s;
  }

  int _byteAt(int h) => (_hops[h].tone << 4) | _hops[h + 4].tone;

  _Hop _measure(int at) {
    final n = modem.symbolSamples;
    var best = 0, total = 0.0, bestP = -1.0;
    for (var t = 0; t < SoundModem.tones; t++) {
      final c = _coeff[t];
      var s1 = 0.0, s2 = 0.0;
      for (var i = 0; i < n; i++) {
        final s0 = _samples[at + i] + c * s1 - s2;
        s2 = s1;
        s1 = s0;
      }
      final p = s1 * s1 + s2 * s2 - c * s1 * s2;
      total += p;
      if (p > bestP) {
        bestP = p;
        best = t;
      }
    }
    return _Hop(best, total > 0 ? bestP / total : 0);
  }

  /// Drops audio and hops that can no longer start a frame, so memory stays
  /// bounded during long listening sessions.
  void _trim() {
    final keepFrom = _scan - 8;
    if (keepFrom < 400) return;
    _hops.removeRange(0, keepFrom);
    _samples.removeRange(0, keepFrom * hop);
    _scan -= keepFrom;
  }
}
