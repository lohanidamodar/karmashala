import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

void main() {
  group('FakePtyLauncher', () {
    test('records the request it was asked to start', () {
      final launcher = FakePtyLauncher();
      final handle = launcher.start(
        const PtySpawnRequest(
          argv: ['/bin/sh', '-l'],
          workingDirectory: '/srv',
          environment: {'TERM': 'xterm-256color'},
          columns: 120,
          rows: 40,
        ),
      );

      expect(launcher.started, hasLength(1));
      expect(launcher.started.single.argv, ['/bin/sh', '-l']);
      expect(launcher.started.single.workingDirectory, '/srv');
      expect(launcher.started.single.columns, 120);
      expect(handle.pid, 1000);
    });

    test('write, resize and kill are recorded, not simulated', () {
      final launcher = FakePtyLauncher();
      final handle = launcher.start(const PtySpawnRequest(argv: ['/bin/sh'])) as FakePtyHandle;

      handle.write(Uint8List.fromList([1, 2, 3]));
      handle.resize(100, 30);
      handle.kill(9);

      expect(handle.writes.single, [1, 2, 3]);
      expect(handle.resizes.single, (100, 30));
      expect(handle.signals.single, 9);
    });

    test('output and exit are driven by the test', () async {
      final launcher = FakePtyLauncher();
      final handle = launcher.start(const PtySpawnRequest(argv: ['/bin/sh'])) as FakePtyHandle;
      final seen = <int>[];
      handle.output.listen(seen.addAll);

      handle.emit([65, 66]);
      await Future<void>.delayed(Duration.zero);
      handle.finish(3);

      expect(seen, [65, 66]);
      expect(await handle.exitCode, 3);
    });

    test('a launcher told to fail refuses instead of starting', () {
      final launcher = FakePtyLauncher()..failWith = const PtyException('no fork for you');
      expect(() => launcher.start(const PtySpawnRequest(argv: ['/bin/sh'])), throwsA(isA<PtyException>()));
      expect(launcher.started, isEmpty);
    });
  });

  group('PtySpawnRequest', () {
    test('copyWith changes only the geometry', () {
      const original = PtySpawnRequest(
        argv: ['/bin/sh'],
        workingDirectory: '/srv',
        environment: {'A': 'b'},
        columns: 80,
        rows: 24,
      );
      final resized = original.copyWith(columns: 100, rows: 30);
      expect(resized.columns, 100);
      expect(resized.rows, 30);
      expect(resized.argv, original.argv);
      expect(resized.workingDirectory, '/srv');
      expect(resized.environment, {'A': 'b'});
    });
  });

  test('PtyException carries errno when there is one', () {
    expect(const PtyException('openpty failed', errno: 24).toString(), contains('errno 24'));
    expect(const PtyException('nope').toString(), isNot(contains('errno')));
  });
}
