// ignore_for_file: avoid_print
import 'dart:math';
import 'dart:typed_data';
import 'package:lightbeam/core/protocol.dart';
import 'package:qr/qr.dart';

void main() {
  final r = Random(1);
  for (final bs in [200, 400, 700, 1000, 1400, 2000]) {
    final data = Uint8List.fromList(List.generate(200000, (_) => r.nextInt(256)));
    final enc = FountainEncoder(TransferFile('x', data), blockSize: bs);
    final texts = [for (var i = 0; i < 60; i++) enc.next().toQrText()];
    QrCode code(String t) => QrCode(payload: QrPayload()..addAlphaNumeric(t), errorCorrectLevel: QrErrorCorrectLevel.low);
    // warm up
    for (final t in texts.take(10)) { QrImage(code(t)); QrImage.withMaskPattern(code(t), 0); }
    final sw = Stopwatch()..start();
    for (final t in texts) { QrImage(code(t)); }
    final best = sw.elapsedMicroseconds / texts.length / 1000;
    sw..reset()..start();
    var i = 0;
    for (final t in texts) { QrImage.withMaskPattern(code(t), i++ % 8); }
    final fixed = sw.elapsedMicroseconds / texts.length / 1000;
    print('bs=$bs version=${code(texts[0]).typeNumber} chars=${texts[0].length} autoMask=${best.toStringAsFixed(2)}ms fixedMask=${fixed.toStringAsFixed(2)}ms');
  }
}
