import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightbeam/core/base45.dart';
import 'package:lightbeam/core/protocol.dart';

Uint8List randomBytes(int n, Random r) =>
    Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));

void main() {
  test('base45 round trip and RFC 9285 vectors', () {
    expect(Base45.encode(Uint8List.fromList('AB'.codeUnits)), 'BB8');
    expect(Base45.encode(Uint8List.fromList('Hello!!'.codeUnits)),
        '%69 VD92EX0');
    final r = Random(1);
    for (var n = 0; n < 50; n++) {
      final d = randomBytes(n, r);
      expect(Base45.decode(Base45.encode(d)), d);
    }
    expect(Base45.decode(':::'), isNull); // value > 65535 is invalid
  });

  test('packet survives QR text round trip', () {
    final enc = FountainEncoder(TransferFile('a.bin', randomBytes(5000, Random(2))),
        blockSize: 300);
    for (var i = 0; i < 40; i++) {
      final p = enc.next();
      final back = Packet.fromQrText(p.toQrText())!;
      expect(back.seq, p.seq);
      expect(back.degree, p.degree);
      expect(back.data, p.data);
    }
  });

  for (final loss in [0.0, 0.3, 0.6]) {
    test('recovers file with ${(loss * 100).round()}% frame loss, late start',
        () {
      final r = Random(42);
      final original = randomBytes(200 * 1024, r); // incompressible
      final enc = FountainEncoder(TransferFile('photo.jpg', original),
          blockSize: 800);
      final rx = Receiver();
      // Receiver opens its camera half way through the systematic pass.
      for (var i = 0; i < enc.k ~/ 2; i++) {
        enc.next();
      }
      var sent = 0;
      while (!rx.isComplete) {
        final p = enc.next();
        sent++;
        if (r.nextDouble() < loss) continue;
        rx.accept(p.toQrText());
        expect(sent, lessThan(enc.k * 10), reason: 'decoder stalled');
      }
      final out = rx.result();
      expect(out.name, 'photo.jpg');
      expect(out.bytes, original);
      final overhead = rx.decoder!.uniquePackets / enc.k - 1;
      // ignore: avoid_print
      print('loss=$loss K=${enc.k} received=${rx.decoder!.uniquePackets} '
          'overhead=${(overhead * 100).toStringAsFixed(1)}%');
    });
  }

  test('compressible data is zlib-packed and verified', () {
    final text = Uint8List.fromList(List.generate(100000, (i) => 65 + i % 7));
    final enc = FountainEncoder(TransferFile('notes.txt', text), blockSize: 500);
    expect(enc.packedSize, lessThan(5000));
    final rx = Receiver();
    while (!rx.isComplete) {
      rx.accept(enc.next().toQrText());
    }
    expect(rx.result().bytes, text);
  });

  test('ignores packets from a different transfer', () {
    final a = FountainEncoder(TransferFile('a', Uint8List(10)), fileId: 1);
    final b = FountainEncoder(TransferFile('b', Uint8List(10)), fileId: 2);
    final rx = Receiver();
    expect(rx.accept(a.next().toQrText()), AcceptResult.newPacket);
    expect(rx.accept(b.next().toQrText()), AcceptResult.otherFile);
    expect(rx.accept('HELLO WORLD'), AcceptResult.invalid);
  });

  test('follows the sender when it restarts with new settings', () {
    final data = randomBytes(3000, Random(5));
    final a = FountainEncoder(TransferFile('f', data), blockSize: 400, fileId: 1);
    final b = FountainEncoder(TransferFile('f', data), blockSize: 200, fileId: 2);
    final rx = Receiver();
    rx.accept(a.next().toQrText());
    while (!rx.isComplete) {
      rx.accept(b.next().toQrText());
    }
    expect(rx.fileId, 2);
    expect(rx.result().bytes, data);
  });
}
