import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightbeam/core/sound.dart';

List<double> _noise(int n, double amp, math.Random r) =>
    [for (var i = 0; i < n; i++) (r.nextDouble() * 2 - 1) * amp];

/// Feeds [audio] in microphone-sized chunks and collects decoded frames.
List<List<int>> _decode(SoundDecoder d, List<double> audio) {
  final out = <List<int>>[];
  for (var i = 0; i < audio.length; i += 1024) {
    out.addAll(d.add(audio.sublist(i, math.min(audio.length, i + 1024))));
  }
  return out;
}

void main() {
  final payload = List<int>.generate(40, (i) => (i * 37 + 11) & 0xFF);

  test('CRC-16/CCITT-FALSE check value', () {
    expect(crc16('123456789'.codeUnits), 0x29B1);
  });

  for (final rate in [44100, 48000]) {
    test('clean round trip at $rate Hz', () {
      final m = SoundModem(sampleRate: rate);
      final frames = _decode(SoundDecoder(m), m.modulate(payload));
      expect(frames, [payload]);
    });
  }

  test('random start offset, noise at 0 dB SNR, back-to-back frames', () {
    final r = math.Random(1);
    final m = SoundModem();
    final a = m.modulate(payload);
    final b = m.modulate([1, 2, 3]);
    final audio = [..._noise(777, 0.5, r), ...a, ...b];
    // Signal RMS is ~0.57; uniform noise of amplitude 1 has RMS ~0.58.
    final noisy = [for (final s in audio) s + (r.nextDouble() * 2 - 1)];
    expect(_decode(SoundDecoder(m), noisy), [payload, [1, 2, 3]]);
  });

  test('room echo and quiet signal', () {
    final m = SoundModem();
    final a = m.modulate(payload);
    final echo = Float32List(a.length + 2400);
    for (var i = 0; i < a.length; i++) {
      echo[i] += 0.05 * a[i];
      echo[i + 700] += 0.03 * a[i]; // 15 ms reflection
      echo[i + 2400] += 0.015 * a[i]; // 50 ms reflection
    }
    expect(_decode(SoundDecoder(m), echo), [payload]);
  });

  test('sender clock 0.1% off from receiver clock', () {
    final tx = SoundModem(sampleRate: 48048);
    final rx = SoundModem();
    expect(_decode(SoundDecoder(rx), tx.modulate(payload)), [payload]);
  });

  test('a corrupted frame is rejected, not mis-delivered', () {
    final m = SoundModem();
    final a = m.modulate(payload);
    // Symbol 20 carries tone 14 (high nibble of payload[6] = 0xE9); swap in tone 3.
    final at = (m.sampleRate * 0.1).round() + 20 * m.symbolSamples;
    for (var i = 0; i < m.symbolSamples; i++) {
      a[at + i] = 0.8 * math.sin(2 * math.pi * m.toneHz(3) * i / m.sampleRate);
    }
    final d = SoundDecoder(m);
    expect(_decode(d, a), isEmpty);
    expect(d.badFrames, greaterThan(0));
  });

  test('silence and pure noise produce nothing', () {
    final r = math.Random(2);
    final d = SoundDecoder(SoundModem());
    expect(_decode(d, _noise(48000 * 10, 0.3, r)), isEmpty);
  });

  test('wav header', () {
    final m = SoundModem();
    final w = m.wav(Float32List.fromList([0, 0.5, -0.5]));
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(w.length, 44 + 6);
  });
}
