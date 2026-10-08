// ignore_for_file: avoid_print
import 'dart:math';
import 'dart:typed_data';
import 'package:lightbeam/core/fountain.dart';

typedef Deg = int Function(RobustSoliton s, Random r, int k);

void main() {
  final strategies = <String, Deg>{
    'soliton': (s, r, k) => s.sample(),
    'floor4': (s, r, k) => max(min(4, k), s.sample()),
    'mix': (s, r, k) => min(k, max(s.sample(), 8 + r.nextInt(8))),
    'dense': (s, r, k) => max(1, k ~/ 2),
    'alt': (s, r, k) => r.nextBool() ? s.sample() : max(1, k ~/ 2),
  };
  for (final k in [20, 60, 257, 800, 1200]) {
    for (final start in [0.0, 0.5]) {
      for (final loss in [0.0, 0.3]) {
        final line = StringBuffer('k=$k start=$start loss=$loss');
        strategies.forEach((name, deg) {
          var total = 0, ms = 0;
          const runs = 8;
          for (var run = 0; run < runs; run++) {
            final r = Random(run * 31 + k);
            final sol = RobustSoliton(k, random: r);
            final dec = FountainDecoder(k, 4);
            var seq = (start * k).round();
            final sw = Stopwatch()..start();
            while (!dec.isComplete) {
              final s = seq++;
              if (r.nextDouble() < loss) continue;
              final d = s < k ? 1 : deg(sol, r, k);
              dec.add(s, blockIndices(9, k, s, d), Uint8List(4));
            }
            ms += sw.elapsedMilliseconds;
            total += dec.uniquePackets;
          }
          line.write('  $name=${((total / (runs * k) - 1) * 100).toStringAsFixed(1)}%/${ms ~/ runs}ms');
        });
        print(line);
      }
    }
  }
}
