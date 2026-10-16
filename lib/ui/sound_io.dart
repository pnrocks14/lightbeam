import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../core/sound.dart';
import '../core/talkback.dart';

/// Plays sound-channel frames through the speaker.
class SoundOut {
  final modem = SoundModem(sampleRate: 48000);
  final _player = AudioPlayer();
  bool _busy = false;

  bool get busy => _busy;

  /// Plays [messages] back to back, once or on a loop.
  Future<void> play(List<SoundMessage> messages, {bool loop = false}) async {
    final samples = <double>[
      for (final m in messages) ...modem.modulate(m.encode()),
    ];
    final wav = modem.wav(Float32List.fromList(samples));
    _busy = true;
    try {
      await _player.stop();
      await _player
          .setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
      await _player.play(BytesSource(wav, mimeType: 'audio/wav'),
          volume: 1.0);
      if (!loop) await _player.onPlayerComplete.first;
    } finally {
      if (!loop) _busy = false;
    }
  }

  Future<void> stop() async {
    _busy = false;
    await _player.stop();
  }

  Future<void> dispose() => _player.dispose();
}

/// Listens to the microphone and decodes sound-channel messages.
class SoundIn {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  int? _carry; // odd trailing byte of a PCM16 chunk

  /// Loudness of the last chunk, 0..1, for a level meter.
  final level = ValueNotifier<double>(0);

  bool get listening => _sub != null;

  /// Starts listening. Returns an error message when the microphone is
  /// unavailable or permission was refused.
  Future<String?> start(void Function(SoundMessage) onMessage) async {
    if (_sub != null) return null;
    try {
      if (!await _recorder.hasPermission()) {
        return 'Microphone permission was denied.';
      }
      const rate = 48000;
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: rate,
        numChannels: 1,
        // Voice processing would filter out the tones.
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition),
        // Built-in mic only: no Bluetooth headsets.
        iosConfig: IosRecordConfig(
            categoryOptions: [IosAudioCategoryOption.defaultToSpeaker]),
      ));
      final decoder = SoundDecoder(SoundModem(sampleRate: rate));
      _sub = stream.listen((chunk) {
        final samples = _pcm16(chunk);
        var peak = 0.0;
        for (final s in samples) {
          if (s.abs() > peak) peak = s.abs();
        }
        level.value = peak;
        for (final frame in decoder.add(samples)) {
          final m = SoundMessage.decode(frame);
          if (m != null) onMessage(m);
        }
      });
      return null;
    } catch (e) {
      await stop();
      return 'Microphone unavailable: $e';
    }
  }

  List<double> _pcm16(Uint8List chunk) {
    var bytes = chunk;
    if (_carry != null) {
      bytes = Uint8List(chunk.length + 1)
        ..[0] = _carry!
        ..setRange(1, chunk.length + 1, chunk);
      _carry = null;
    }
    final n = bytes.length >> 1;
    if (bytes.length.isOdd) _carry = bytes.last;
    final d = ByteData.sublistView(bytes);
    return [for (var i = 0; i < n; i++) d.getInt16(i * 2, Endian.little) / 32768];
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _carry = null;
    level.value = 0;
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
    level.dispose();
  }
}
