import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../core/protocol.dart';

/// Builds the QR symbol for one packet. Base45 text goes in QR alphanumeric
/// mode with the lowest error-correction level: the fountain code already
/// tolerates lost frames, so QR redundancy is better spent on payload.
///
/// The mask is rotated by sequence number instead of searched. Scoring all
/// eight masks costs ~8x more time (5.3 ms vs 0.6 ms per code at 700 B) and
/// buys nothing for random-looking data; a frame that happens to scan badly
/// is simply replaced by the next one.
QrImage packetToQr(Packet p) => QrImage.withMaskPattern(
    QrCode(
      payload: QrPayload()..addAlphaNumeric(p.toQrText()),
      errorCorrectLevel: QrErrorCorrectLevel.low,
    ),
    p.seq % 8);

class QrView extends StatelessWidget {
  final QrImage image;
  const QrView(this.image, {super.key});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: RepaintBoundary(
        child: CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;
  _QrPainter(this.image);

  static const quiet = 3; // modules of white border

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final unit = size.width / (n + quiet * 2);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final path = Path();
    for (var r = 0; r < n; r++) {
      var c = 0;
      while (c < n) {
        if (!image.isDark(r, c)) {
          c++;
          continue;
        }
        final start = c;
        while (c < n && image.isDark(r, c)) {
          c++;
        }
        // One rect per horizontal run; tiny overlap avoids hairline seams.
        path.addRect(Rect.fromLTWH((start + quiet) * unit, (r + quiet) * unit,
            (c - start) * unit + 0.5, unit + 0.5));
      }
    }
    canvas.drawPath(path, Paint()..color = Colors.black..isAntiAlias = false);
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
