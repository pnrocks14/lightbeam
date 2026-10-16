import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lightbeam/core/sound.dart';
import 'package:lightbeam/core/talkback.dart';

void main() {
  test('progress and done round trip', () {
    final p = SoundMessage.decode(const ProgressMessage(0xDEADBEEF, 63, true).encode());
    expect(p, isA<ProgressMessage>());
    p as ProgressMessage;
    expect([p.fileId, p.percent, p.struggling], [0xDEADBEEF, 63, true]);
    final d = SoundMessage.decode(const DoneMessage(7).encode()) as DoneMessage;
    expect(d.fileId, 7);
    expect(SoundMessage.decode([0x00, 1, 2]), isNull);
    expect(SoundMessage.decode([]), isNull);
  });

  test('text chunks reassemble in any order, with duplicates', () {
    final text = 'Wi-Fi: LightBeam-Guest / pass: ünïcødé ✓ ${'x' * 100}';
    final chunks = chunkText(text, messageId: 42);
    expect(chunks.length, greaterThan(3));
    final a = TextAssembler();
    String? out;
    for (final c in [...chunks.reversed, chunks[1], chunks[0]]) {
      final m = SoundMessage.decode(c.encode()) as TextChunk;
      out = a.add(m) ?? out;
    }
    expect(out, text);
  });

  test('a new message id resets the assembler', () {
    final a = TextAssembler();
    final old = chunkText('a' * 70, messageId: 1);
    a.add(old[0]);
    final fresh = chunkText('hello', messageId: 2);
    expect(a.add(fresh[0]), 'hello');
  });

  test('text size limits', () {
    expect(() => chunkText(''), throwsArgumentError);
    expect(() => chunkText('x' * (maxSoundText + 1)), throwsArgumentError);
  });

  test('a whole text message survives the modem with noise', () {
    final m = SoundModem();
    final r = math.Random(3);
    final chunks = chunkText('Meet at gate 12, code 4471. Bring the drive.');
    final audio = <double>[
      for (final c in chunks) ...m.modulate(c.encode()),
    ];
    final noisy = [for (final s in audio) 0.2 * s + (r.nextDouble() - 0.5) * 0.2];
    final d = SoundDecoder(m);
    final a = TextAssembler();
    String? out;
    for (var i = 0; i < noisy.length; i += 2048) {
      for (final f in d.add(noisy.sublist(i, math.min(noisy.length, i + 2048)))) {
        final msg = SoundMessage.decode(f);
        if (msg is TextChunk) out = a.add(msg) ?? out;
      }
    }
    expect(out, 'Meet at gate 12, code 4471. Bring the drive.');
  });
}
