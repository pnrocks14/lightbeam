import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/fountain.dart';
import '../core/protocol.dart';
import 'format.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
    formats: const [BarcodeFormat.qrCode],
    cameraResolution: const Size(1920, 1080),
  );
  final _tick = ValueNotifier<int>(0);
  Receiver _rx = Receiver();
  TransferFile? _result;
  String? _error;
  int _failedAttempts = 0;
  // Refreshes the panel once a second so "stalled" hints appear even when no
  // codes arrive at all.
  late final Timer _clock =
      Timer.periodic(const Duration(seconds: 1), (_) => _tick.value++);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _clock;
  }

  @override
  void dispose() {
    _clock.cancel();
    WakelockPlus.disable();
    _controller.dispose();
    _tick.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_result != null) return;
    var changed = false;
    for (final b in capture.barcodes) {
      final text = b.rawValue;
      if (text == null) continue;
      try {
        if (_rx.accept(text) == AcceptResult.newPacket) changed = true;
      } catch (e) {
        // A decoder bug must never kill the camera loop; start clean.
        _restartAfterFailure('Internal decoder error ($e)');
        return;
      }
    }
    if (!changed) return;
    _tick.value++;
    if (_rx.isComplete) _finish();
  }

  void _finish() {
    try {
      final file = _rx.result();
      _controller.stop();
      HapticFeedback.heavyImpact();
      setState(() => _result = file);
    } on FormatException catch (e) {
      _restartAfterFailure(e.message);
    }
  }

  /// Every packet passed its CRC, so a failed SHA-256 means something rare
  /// (a CRC collision, or a sender bug). The fix is the same: drop
  /// everything and keep listening. The sender loops, so nothing is lost.
  void _restartAfterFailure(String reason) {
    _failedAttempts++;
    setState(() {
      _rx = Receiver();
      _error = 'Verification failed ($reason). Restarted automatically, '
          'keep pointing at the sender (attempt ${_failedAttempts + 1}).';
    });
  }

  void _reset() {
    setState(() {
      _rx = Receiver();
      _result = null;
      _error = null;
    });
    _controller.start();
  }

  Future<void> _save() async {
    final file = _result!;
    final dot = file.name.lastIndexOf('.');
    final base = dot > 0 ? file.name.substring(0, dot) : file.name;
    final ext = dot > 0 ? file.name.substring(dot + 1) : '';
    try {
      final path = await FileSaver.instance.saveAs(
        name: base,
        bytes: file.bytes,
        fileExtension: ext,
        mimeType: MimeType.other,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(path == null || path.isEmpty ? 'Saved' : 'Saved to $path')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive'),
        actions: [
          IconButton(
            tooltip: 'Start over',
            icon: const Icon(Icons.restart_alt),
            onPressed: _reset,
          ),
        ],
      ),
      body: _result != null
          ? _ResultView(file: _result!, onSave: _save, onAgain: _reset)
          : Stack(children: [
              Positioned.fill(
                child: MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_cameraHelp(error),
                          textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: ValueListenableBuilder(
                  valueListenable: _tick,
                  builder: (context, _, _) => _ProgressPanel(_rx, _error),
                ),
              ),
            ]),
    );
  }
}

String _cameraHelp(MobileScannerException error) {
  switch (error.errorCode) {
    case MobileScannerErrorCode.permissionDenied:
      return 'Camera permission was denied.\n\nAllow camera access for '
          'LightBeam in your device or browser settings, then reopen Receive.';
    case MobileScannerErrorCode.unsupported:
      return 'This device cannot scan with its camera here.\n\nOn Windows '
          'or Linux, open the LightBeam web app in a browser to use the '
          'webcam.';
    default:
      return 'Camera unavailable: ${error.errorCode.message}\n\n'
          'Close other apps using the camera and try again. In a browser, '
          'the page must be served from localhost or https.';
  }
}

class _ProgressPanel extends StatelessWidget {
  final Receiver rx;
  final String? error;
  const _ProgressPanel(this.rx, this.error);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dec = rx.decoder;
    final started = rx.firstPacketAt;
    String title;
    String? hint;
    var rate = '–', eta = '–';
    final idle = rx.lastNewPacketAt == null
        ? null
        : DateTime.now().difference(rx.lastNewPacketAt!).inSeconds;
    if (rx.versionClash && dec == null) {
      hint = 'The sender runs a different LightBeam version. Update both '
          'devices to the same version.';
    } else if (idle != null && idle >= 4) {
      hint = 'No new data for ${idle}s. Move closer, cut glare, or lower '
          'the sender\'s speed or density.';
    } else if (rx.corruptScans > 0 && rx.corruptScans * 5 > rx.validScans) {
      hint = 'Many damaged frames. Hold steadier or lower the sender speed.';
    }
    if (dec == null) {
      title = 'Point the camera at the sender\'s screen';
    } else {
      title = '${(rx.progress * 100).toStringAsFixed(1)}% of '
          '${formatBytes(dec.k * dec.blockSize)}';
      if (started != null) {
        final secs =
            DateTime.now().difference(started).inMilliseconds / 1000.0;
        if (secs > 0.5) {
          final perSec = dec.uniquePackets / secs;
          rate = '${formatBytes((perSec * dec.blockSize).round())}/s';
          final remaining = math.max(0, dec.k * (1.01 - rx.progress));
          eta = perSec > 0 ? formatDuration(remaining / perSec) : '–';
        }
      }
    }
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 560),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          Text(title, style: theme.textTheme.titleMedium),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(hint,
                  style: TextStyle(color: theme.colorScheme.tertiary)),
            ),
          if (dec != null) ...[
            const SizedBox(height: 10),
            SizedBox(height: 56, child: CustomPaint(painter: _BlockMap(dec))),
            const SizedBox(height: 10),
            Wrap(spacing: 18, runSpacing: 4, children: [
              Text('Blocks ${dec.solved}/${dec.k}'),
              Text('Packets ${dec.uniquePackets}'),
              Text('Speed $rate'),
              Text('Left $eta'),
              if (rx.corruptScans > 0) Text('Rejected ${rx.corruptScans}'),
            ]),
          ],
        ],
      ),
    );
  }
}

/// One cell per source block; lights up as blocks are recovered.
class _BlockMap extends CustomPainter {
  final FountainDecoder dec;
  _BlockMap(this.dec);

  @override
  void paint(Canvas canvas, Size size) {
    final k = dec.k;
    final cols = math.max(1, math.sqrt(k * size.width / size.height).ceil());
    final rows = (k / cols).ceil();
    final w = size.width / cols, h = size.height / rows;
    final on = Paint()..color = const Color(0xFF00E5FF);
    final off = Paint()..color = const Color(0x33FFFFFF);
    final gap = math.min(w, h) > 4 ? 1.0 : 0.0;
    for (var i = 0; i < k; i++) {
      final r = Rect.fromLTWH(
          (i % cols) * w, (i ~/ cols) * h, w - gap, h - gap);
      canvas.drawRect(r, dec.blocks[i] != null ? on : off);
    }
  }

  @override
  bool shouldRepaint(_BlockMap old) => true;
}

class _ResultView extends StatelessWidget {
  final TransferFile file;
  final VoidCallback onSave;
  final VoidCallback onAgain;
  const _ResultView(
      {required this.file, required this.onSave, required this.onAgain});

  String? get _text {
    if (!file.name.endsWith('.txt') || file.bytes.length > 200000) return null;
    try {
      return utf8.decode(file.bytes);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _text;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Icon(Icons.verified, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(file.name,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall),
            Text('${formatBytes(file.bytes.length)} · SHA-256 verified',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            if (text != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(text),
                ),
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy text'),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.save_alt),
              label: const Padding(
                  padding: EdgeInsets.all(12), child: Text('Save file')),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: onAgain, child: const Text('Receive another')),
          ],
        ),
      ),
    );
  }
}
