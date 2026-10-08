import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightbeam/core/base45.dart';
import 'package:lightbeam/core/fountain.dart';
import 'package:lightbeam/core/protocol.dart';

Uint8List randomBytes(int n, Random r) =>
    Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));

/// Re-encodes [bytes] as a packet whose CRC is recomputed, so only the
/// semantic checks can catch it.
String reseal(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  final p = Packet(b.getUint32(2), b.getUint32(6), b.getUint16(10),
      b.getUint32(12), b.getUint16(16), Uint8List.sublistView(bytes, headerSize));
  return p.toQrText();
}

void main() {
  group('cross-platform determinism', () {
    // Recorded on the Dart VM. The same test runs in Chrome
    // (`flutter test --platform chrome`), proving web and native senders
    // pick identical blocks for every packet.
    test('PRNG and block choice match golden vectors', () {
      expect([for (var s = 0; s < 4; s++) StreamRng(0xDEADBEEF, s).next()],
          [820393431, 3192644752, 800814980, 2691833329]);
      expect(blockIndices(0xDEADBEEF, 1000, 5000, 6),
          [647, 655, 434, 915, 295, 930]);
      expect(blockIndices(7, 50, 77, 40).take(8), [23, 2, 8, 31, 21, 26, 20, 11]);
    });
  });

  group('packet integrity', () {
    final enc = FountainEncoder(
        TransferFile('a.bin', randomBytes(20000, Random(1))),
        blockSize: 400,
        fileId: 99);

    test('every single-bit flip is rejected by the CRC', () {
      final bytes = enc.next().toBytes();
      for (var bit = 0; bit < bytes.length * 8; bit++) {
        final copy = Uint8List.fromList(bytes);
        copy[bit >> 3] ^= 1 << (bit & 7);
        final (p, status) = Packet.parse(Base45.encode(copy));
        expect(p, isNull, reason: 'bit $bit');
        expect(status,
            anyOf(AcceptResult.corrupt, AcceptResult.invalid,
                AcceptResult.incompatibleVersion));
      }
    });

    test('random multi-byte corruption never gets through', () {
      final r = Random(3);
      var rejected = 0;
      for (var i = 0; i < 3000; i++) {
        final original = enc.next().toBytes();
        final copy = Uint8List.fromList(original);
        for (var j = 0; j < 1 + r.nextInt(6); j++) {
          copy[r.nextInt(copy.length)] = r.nextInt(256);
        }
        copy[0] = packetMagic; // keep it looking like ours
        copy[1] = protocolVersion;
        if (Packet.fromQrText(Base45.encode(copy)) == null) {
          rejected++;
        } else {
          // Accepted only when the random writes left the bytes unchanged.
          expect(copy, original);
        }
      }
      expect(rejected, greaterThan(2900));
    });

    test('truncated and non-LightBeam codes are ignored', () {
      final text = enc.next().toQrText();
      expect(Packet.parse(text.substring(0, text.length - 3)).$2,
          AcceptResult.corrupt);
      expect(Packet.parse('https://example.com').$2, AcceptResult.invalid);
      expect(Packet.parse('').$2, AcceptResult.invalid);
      expect(Packet.parse('HELLO WORLD').$2, AcceptResult.invalid);
    });

    test('other protocol versions are reported, not misread', () {
      final bytes = enc.next().toBytes();
      bytes[1] = 1;
      expect(Packet.parse(Base45.encode(bytes)).$2,
          AcceptResult.incompatibleVersion);
    });

    test('headers that pass the CRC but are impossible are rejected', () {
      Uint8List fresh() => enc.next().toBytes();
      final hugeK = fresh();
      ByteData.sublistView(hugeK).setUint32(6, 0x7FFFFFFF);
      final zeroBlock = fresh();
      ByteData.sublistView(zeroBlock).setUint16(16, 0);
      final systematicWithDegree = enc.next().toBytes();
      final b = ByteData.sublistView(systematicWithDegree);
      b.setUint32(12, 0); // seq < K ...
      b.setUint16(16, 3); // ... but degree 3
      for (final bad in [hugeK, zeroBlock, systematicWithDegree]) {
        expect(Packet.parse(reseal(bad)).$2, AcceptResult.corrupt);
      }
    });
  });

  group('file container', () {
    test('path traversal and odd characters are stripped from names', () {
      expect(TransferFile.safeFileName('../../etc/passwd'), 'passwd');
      expect(TransferFile.safeFileName(r'C:\Users\x\evil.exe'), 'evil.exe');
      expect(TransferFile.safeFileName('..'), 'received.bin');
      expect(TransferFile.safeFileName('a\u0000b?.txt'), 'a_b_.txt');
      expect(TransferFile.safeFileName('${'x' * 300}.pdf').length, 120);
      expect(TransferFile.safeFileName('${'x' * 300}.pdf'), endsWith('.pdf'));
    });

    test('damaged containers raise FormatException, never crash', () {
      final packed = TransferFile('t.txt', Uint8List.fromList(List.filled(5000, 65)))
          .pack();
      final r = Random(9);
      for (var i = 0; i < 500; i++) {
        final copy = Uint8List.fromList(packed);
        final cut = r.nextBool();
        final data = cut ? copy.sublist(0, r.nextInt(copy.length)) : copy;
        if (!cut) data[r.nextInt(data.length)] ^= 1 + r.nextInt(255);
        try {
          TransferFile.unpack(data);
        } on FormatException {
          continue;
        }
        // Survived: must then be byte-identical content (flip hit padding).
        expect(TransferFile.unpack(data).bytes, List.filled(5000, 65));
      }
    });
  });

  group('receiver resilience', () {
    test('completes with foreign QR codes and corrupt frames mixed in', () {
      final r = Random(11);
      final data = randomBytes(60000, r);
      final enc = FountainEncoder(TransferFile('mix.bin', data), blockSize: 700);
      final rx = Receiver();
      while (!rx.isComplete) {
        final roll = r.nextDouble();
        if (roll < 0.15) {
          rx.accept('https://example.com/menu');
        } else if (roll < 0.30) {
          final bytes = enc.next().toBytes();
          bytes[headerSize + r.nextInt(bytes.length - headerSize)] ^= 0x40;
          expect(rx.accept(Base45.encode(bytes)), AcceptResult.corrupt);
        } else {
          rx.accept(enc.next().toQrText());
        }
      }
      expect(rx.result().bytes, data);
      expect(rx.corruptScans, greaterThan(0));
    });

    test('rejects a packet that reuses the transfer id with another shape', () {
      final a = FountainEncoder(TransferFile('a', Uint8List(5000)),
          blockSize: 400, fileId: 5);
      final b = FountainEncoder(TransferFile('b', Uint8List(5000)),
          blockSize: 200, fileId: 5);
      final rx = Receiver()..accept(a.next().toQrText());
      expect(rx.accept(b.next().toQrText()), AcceptResult.corrupt);
    });

    test('encoder refuses files beyond the size limit', () {
      final r = Random(2);
      // Incompressible, just over the limit.
      final big = randomBytes(maxTransferBytes + 1024, r);
      expect(() => FountainEncoder(TransferFile('big', big)),
          throwsA(isA<FileTooLargeException>()));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
