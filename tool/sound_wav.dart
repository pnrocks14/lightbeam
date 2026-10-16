// Writes a WAV of a sound-channel text message (looped), for testing a
// listener with a fake microphone: dart run tool/sound_wav.dart out.wav "text"
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lightbeam/core/sound.dart';
import 'package:lightbeam/core/talkback.dart';

void main(List<String> args) {
  final m = SoundModem();
  final chunks = chunkText(args[1]);
  final r = math.Random(5);
  final loop = [for (final c in chunks) ...m.modulate(c.encode())];
  // Quiet signal plus room hiss, as a microphone a metre away might hear it.
  final audio = [
    for (var i = 0; i < 2; i++)
      for (final s in loop) 0.3 * s + (r.nextDouble() - 0.5) * 0.1,
  ];
  File(args[0]).writeAsBytesSync(m.wav(Float32List.fromList(audio)));
  print('${chunks.length} chunks, ${(audio.length / m.sampleRate).toStringAsFixed(1)} s');
}
