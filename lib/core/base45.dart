import 'dart:typed_data';

/// Base45 (RFC 9285). Its 45-character alphabet is exactly the QR
/// "alphanumeric" set, so a QR code stores it at 5.5 bits per character:
/// 2 bytes -> 3 chars -> 16.5 bits, i.e. ~97% efficiency. Base64 in QR byte
/// mode only reaches 75%.
class Base45 {
  static const alphabet = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';
  static final Map<int, int> _lookup = {
    for (var i = 0; i < alphabet.length; i++) alphabet.codeUnitAt(i): i,
  };

  static String encode(Uint8List data) {
    final out = StringBuffer();
    var i = 0;
    for (; i + 1 < data.length; i += 2) {
      var n = data[i] * 256 + data[i + 1];
      final c = n % 45;
      n ~/= 45;
      final d = n % 45;
      final e = n ~/ 45;
      out
        ..writeCharCode(alphabet.codeUnitAt(c))
        ..writeCharCode(alphabet.codeUnitAt(d))
        ..writeCharCode(alphabet.codeUnitAt(e));
    }
    if (i < data.length) {
      final n = data[i];
      out
        ..writeCharCode(alphabet.codeUnitAt(n % 45))
        ..writeCharCode(alphabet.codeUnitAt(n ~/ 45));
    }
    return out.toString();
  }

  /// Returns null when [s] is not valid Base45.
  static Uint8List? decode(String s) {
    if (s.length % 3 == 1) return null;
    final out = Uint8List(s.length ~/ 3 * 2 + (s.length % 3 == 2 ? 1 : 0));
    var o = 0;
    for (var i = 0; i < s.length; i += 3) {
      final c = _lookup[s.codeUnitAt(i)];
      final d = _lookup[s.codeUnitAt(i + 1)];
      if (c == null || d == null) return null;
      if (i + 2 < s.length) {
        final e = _lookup[s.codeUnitAt(i + 2)];
        if (e == null) return null;
        final n = c + d * 45 + e * 45 * 45;
        if (n > 0xFFFF) return null;
        out[o++] = n >> 8;
        out[o++] = n & 0xFF;
      } else {
        final n = c + d * 45;
        if (n > 0xFF) return null;
        out[o++] = n;
      }
    }
    return out;
  }
}
