import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/protocol.dart';
import '../core/talkback.dart';
import 'format.dart';
import 'qr_view.dart';
import 'sound_io.dart';
import 'sound_screens.dart';

/// Bytes of file data per QR code. All multiples of 4 (fast XOR path).
const densities = <int, String>{
  200: 'Very easy',
  400: 'Easy',
  700: 'Balanced',
  1000: 'Dense',
  1400: 'Very dense',
  2000: 'Extreme',
};

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen>
    with SingleTickerProviderStateMixin {
  TransferFile? _file;
  FountainEncoder? _encoder;
  List<QrImage> _frames = const [];
  List<QrImage>? _prefetched;
  late final Ticker _ticker = createTicker(_onVsync);
  Duration _now = Duration.zero;
  Duration _nextDue = Duration.zero;
  bool _paused = false;
  bool _showSettings = false;
  int _framesShown = 0;

  int _blockSize = 700;
  double _fps = 10;
  bool _grid = false;

  // Talk-back: the receiver's chirps, heard through the microphone.
  final _ears = SoundIn();
  bool _listen = false;
  int? _rxPercent;
  bool _rxDone = false;

  int get _codesPerFrame => _grid ? 4 : 1;

  @override
  void dispose() {
    _ears.dispose();
    _ticker.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFile() async {
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      _start(TransferFile(picked.name, bytes));
    } catch (e) {
      _toast('Could not open that file: $e');
    }
  }

  Future<void> _enterText({bool bySound = false}) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(bySound ? 'Send a message by sound' : 'Send a message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          maxLength: bySound ? maxSoundText : null,
          decoration: const InputDecoration(
              hintText: 'Text, a link, a password...',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Beam it')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    if (bySound) {
      try {
        chunkText(text);
      } catch (e) {
        _toast('Too long for sound: keep it under $maxSoundText bytes.');
        return;
      }
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => SoundSendScreen(text)));
      return;
    }
    _start(TransferFile('message.txt', Uint8List.fromList(utf8.encode(text))));
  }

  void _start(TransferFile file) {
    _file = file;
    if (!_restart()) return;
    if (!_ticker.isActive) _ticker.start();
    WakelockPlus.enable();
  }

  /// (Re)builds the encoder. A new transfer id tells receivers that the
  /// packet layout changed, so they start over cleanly.
  bool _restart() {
    final file = _file;
    if (file == null) return false;
    try {
      _encoder = FountainEncoder(file, blockSize: _blockSize);
    } catch (e) {
      _toast('$e');
      setState(() {
        _file = null;
        _encoder = null;
      });
      return false;
    }
    _framesShown = 0;
    _rxPercent = null;
    _rxDone = false;
    _paused = false;
    _prefetched = null;
    _showNext();
    _nextDue = _now + _period;
    return true;
  }

  Future<void> _setListen(bool on) async {
    setState(() => _listen = on);
    if (!on) {
      await _ears.stop();
      return;
    }
    final error = await _ears.start(_onSound);
    if (error != null) {
      _toast(error);
      if (mounted) setState(() => _listen = false);
    }
  }

  /// A chirp from the receiver. Speed adapts like TCP: back off sharply
  /// when it struggles, creep up while it keeps up.
  void _onSound(SoundMessage m) {
    final enc = _encoder;
    if (enc == null || _rxDone) return;
    if (m is DoneMessage && m.fileId == enc.fileId) {
      HapticFeedback.heavyImpact();
      setState(() {
        _rxDone = true;
        _rxPercent = 100;
        _paused = true;
      });
      WakelockPlus.disable();
    } else if (m is ProgressMessage && m.fileId == enc.fileId) {
      setState(() {
        _rxPercent = m.percent;
        if (m.struggling) {
          _fps = (_fps * 0.7).roundToDouble().clamp(3, 30);
        } else if (_fps < 20) {
          _fps += 1;
        }
      });
    }
  }

  Duration get _period => Duration(microseconds: (1e6 / _fps).round());

  /// Called once per display refresh. Frames change only on a vsync, never
  /// half-way through a screen refresh, and the next frame is built right
  /// after a swap so its cost hides inside the current frame's display time.
  void _onVsync(Duration now) {
    _now = now;
    if (_paused || _encoder == null) return;
    if (now < _nextDue) return;
    _nextDue += _period;
    if (now >= _nextDue) _nextDue = now + _period; // fell behind: resync
    _showNext();
  }

  void _showNext() {
    final frames = _prefetched ?? _build();
    setState(() {
      _frames = frames;
      _framesShown++;
    });
    _prefetched = _build();
  }

  List<QrImage> _build() {
    final enc = _encoder!;
    return [for (var i = 0; i < _codesPerFrame; i++) packetToQr(enc.next())];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_file?.name ?? 'Send'),
        actions: [
          if (_encoder != null) ...[
            IconButton(
              tooltip: _paused ? 'Resume' : 'Pause',
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              onPressed: () {
                setState(() => _paused = !_paused);
                _nextDue = _now;
              },
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.tune),
              onPressed: () => setState(() => _showSettings = !_showSettings),
            ),
          ],
        ],
      ),
      body: SafeArea(child: _encoder == null ? _picker() : _transmitter()),
    );
  }

  Widget _picker() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.insert_drive_file),
              label: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Choose a file', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _enterText,
              icon: const Icon(Icons.short_text),
              label: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Type a message', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _enterText(bySound: true),
              icon: const Icon(Icons.graphic_eq),
              label: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Send a message by sound',
                    style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 24),
            _settings(),
          ],
        ),
      ),
    );
  }

  Widget _settings() {
    final theme = Theme.of(context);
    final rate = _blockSize * _fps * _codesPerFrame;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Density: ${densities[_blockSize]} ($_blockSize B per code)',
                style: theme.textTheme.titleSmall),
            Slider(
              value: densities.keys.toList().indexOf(_blockSize).toDouble(),
              max: densities.length - 1.0,
              divisions: densities.length - 1,
              onChanged: (v) {
                setState(() => _blockSize = densities.keys.elementAt(v.round()));
              },
              onChangeEnd: (_) => _restart(),
            ),
            Text('Speed: ${_fps.round()} frames/s',
                style: theme.textTheme.titleSmall),
            Slider(
              value: _fps,
              min: 2,
              max: 30,
              divisions: 28,
              onChanged: (v) {
                setState(() => _fps = v.roundToDouble());
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Quad mode (2×2 codes)'),
              subtitle: const Text(
                  '4× throughput on big screens. Best with phone receivers.'),
              value: _grid,
              onChanged: (v) {
                setState(() => _grid = v);
                if (_encoder != null) {
                  _prefetched = null;
                  _showNext();
                }
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Listen to the receiver'),
              subtitle: const Text('Uses the microphone. The receiver chirps '
                  'its progress; speed adapts and sending stops when it is '
                  'done.'),
              value: _listen,
              onChanged: _setListen,
            ),
            Text('Air rate: ${formatBytes(rate.round())}/s',
                style: TextStyle(color: theme.colorScheme.primary)),
            Text(
              'Lower density and speed if the receiver struggles; raise them '
              'when it keeps up.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transmitter() {
    final enc = _encoder!;
    final theme = Theme.of(context);
    final needed = (enc.k * 1.02 / _codesPerFrame).ceil();
    final seconds = needed / _fps;
    return Column(
      children: [
        if (_showSettings)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _settings(),
          ),
        Expanded(
          child: Container(
            color: Colors.white,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, c) {
              final side = c.biggest.shortestSide;
              if (!_grid) {
                return SizedBox.square(dimension: side, child: QrView(_frames[0]));
              }
              return SizedBox.square(
                dimension: side,
                child: GridView.count(
                  crossAxisCount: 2,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [for (final f in _frames) QrView(f)],
                ),
              );
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 20,
            runSpacing: 6,
            children: [
              _stat('Size', formatBytes(_file!.bytes.length)),
              _stat('Packed', formatBytes(enc.packedSize)),
              _stat('Blocks', '${enc.k}'),
              _stat('Frame', '$_framesShown'),
              _stat('Est. time', formatDuration(seconds)),
            ],
          ),
        ),
        if (_listen)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _rxDone
                  ? 'Receiver has the file. Sending stopped.'
                  : _rxPercent == null
                      ? 'Listening for the receiver...'
                      : 'Receiver at $_rxPercent% · ${_fps.round()} frames/s',
              style: theme.textTheme.titleSmall?.copyWith(
                  color: _rxDone ? theme.colorScheme.primary : null),
            ),
          ),
        Text(
          'Keep this screen bright and steady. It loops until you stop it.',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _stat(String label, String value) {
    final theme = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(value, style: theme.textTheme.titleMedium),
      Text(label,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    ]);
  }
}
