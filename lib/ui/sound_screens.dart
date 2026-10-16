import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/sound.dart';
import '../core/talkback.dart';
import 'sound_io.dart';

/// Plays a short text by sound, on a loop, until stopped.
class SoundSendScreen extends StatefulWidget {
  final String text;
  const SoundSendScreen(this.text, {super.key});

  @override
  State<SoundSendScreen> createState() => _SoundSendScreenState();
}

class _SoundSendScreenState extends State<SoundSendScreen> {
  final _out = SoundOut();
  late final List<TextChunk> _chunks = chunkText(widget.text);
  String? _error;

  double get _loopSeconds =>
      _chunks.fold(
          0.0,
          (t, c) =>
              t +
              SoundModem.frameLength(c.encode().length) *
                  SoundModem.symbolSeconds) +
      0.2 * _chunks.length;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _out.play(_chunks, loop: true).catchError((Object e) {
      if (mounted) setState(() => _error = 'Could not play sound: $e');
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sending by sound')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(Icons.graphic_eq, size: 72, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                _error ??
                    'Playing ${_chunks.length} chunk${_chunks.length == 1 ? '' : 's'} '
                        'on a loop (${_loopSeconds.toStringAsFixed(0)} s each round).',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'On the other device open Listen. Keep the phones within about '
                'a metre, turn the volume up, and keep the room quiet. The '
                'listener can join at any moment.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.stop),
                label: const Padding(
                    padding: EdgeInsets.all(12), child: Text('Stop')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Listens to the microphone for a short text sent by sound.
class ListenScreen extends StatefulWidget {
  const ListenScreen({super.key});

  @override
  State<ListenScreen> createState() => _ListenScreenState();
}

class _ListenScreenState extends State<ListenScreen> {
  final _in = SoundIn();
  final _assembler = TextAssembler();
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _start();
  }

  Future<void> _start() async {
    final error = await _in.start(_onMessage);
    if (mounted) setState(() => _error = error);
  }

  void _onMessage(SoundMessage m) {
    if (m is! TextChunk || _text != null) return;
    final text = _assembler.add(m);
    setState(() {});
    if (text != null) {
      HapticFeedback.heavyImpact();
      _in.stop();
      setState(() => _text = text);
    }
  }

  void _again() {
    setState(() {
      _text = null;
      _assembler.messageId = null;
    });
    _start();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _text;
    return Scaffold(
      appBar: AppBar(title: const Text('Listen')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: text != null
                ? [
                    Icon(Icons.verified,
                        size: 72, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(text,
                            style: theme.textTheme.titleMedium),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: text)),
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy text'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                        onPressed: _again,
                        child: const Text('Listen again')),
                  ]
                : [
                    ValueListenableBuilder(
                      valueListenable: _in.level,
                      builder: (context, level, _) => Icon(Icons.hearing,
                          size: 72 + 40 * level.clamp(0.0, 1.0),
                          color: theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error ??
                          (_assembler.total == 0
                              ? 'Listening for a LightBeam sound message...'
                              : 'Got ${_assembler.received} of '
                                  '${_assembler.total} pieces'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: _error != null
                              ? theme.colorScheme.error
                              : null),
                    ),
                    if (_assembler.total > 0) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                          value: _assembler.received / _assembler.total),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Hold this device near the sender\'s speaker. Missed '
                      'pieces come round again on the next loop.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
          ),
        ),
      ),
    );
  }
}
