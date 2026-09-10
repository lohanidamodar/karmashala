@Tags(['cost'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/adb_service.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/data/device_stream.dart';
import 'package:test/test.dart';

import './support/fake_command_runner.dart';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

/// A staging directory of this test's own: a test writing four dummy bytes must
/// not reach the file a live session is about to push to a phone.
Directory _staging() {
  final dir = Directory.systemTemp.createTempSync('cg_scrcpy_stage');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Names in [directory] that a start staged or left behind.
List<String> _stagedNames(Directory directory) => [
  for (final entity in directory.listSync())
    if (entity.uri.pathSegments.last.startsWith(kScrcpyHostJarPrefix))
      entity.uri.pathSegments.last,
];

/// A runner whose `forward tcp:0` answers with a port nothing is listening on,
/// so both attempts run to exhaustion — and which records the size of the file
/// each `adb push` was handed, at the moment of the push.
FakeCommandRunner _pushRecorder(List<({String path, int length})> pushes) =>
    FakeCommandRunner(
      responder: (request) {
        if (request.arguments.contains('push')) {
          final file = File(request.arguments[3]);
          pushes.add((
            path: file.path,
            length: file.existsSync() ? file.lengthSync() : -1,
          ));
        }
        if (request.arguments.contains('forward') &&
            request.arguments.contains('tcp:0')) {
          return const CommandResult(exitCode: 0, stdout: '1\n', stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );

void main() {
  group('parseForwardedPort', () {
    test('reads the port adb allocated for tcp:0', () {
      expect(parseForwardedPort('54321\n'), 54321);
    });

    test('ignores surrounding chatter', () {
      expect(
        parseForwardedPort('* daemon started successfully\n49152\n'),
        49152,
      );
    });

    test('returns null when adb printed no port', () {
      expect(parseForwardedPort(''), isNull);
      expect(parseForwardedPort('error: device offline'), isNull);
    });
  });

  group('reapOrphans', () {
    DeviceStreamService serviceOver(FakeCommandRunner runner) =>
        DeviceStreamService(
          adb: AdbService(runner: runner, sdk: _sdk()),
          runner: runner,
          serverBytes: () async => Uint8List(0),
        );

    test('kills our leaked servers and removes our stale forwards', () async {
      // Both leaks were observed on this machine at once: a server that had
      // exited with its forward still registered, and four servers alive.
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('ps')) {
            return const CommandResult(
              exitCode: 0,
              stdout:
                  ' 11026 sh -c CLASSPATH=/data/local/tmp/'
                  'karmashala-scrcpy-server.jar app_process / '
                  'com.genymobile.scrcpy.Server 4.1 scid=3f3c4fef\n'
                  ' 11028 app_process / com.genymobile.scrcpy.Server 4.1 '
                  'scid=3f3c4fef\n',
              stderr: '',
            );
          }
          if (request.arguments.contains('--list')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'emulator-5554 tcp:57521 localabstract:scrcpy_12a9795f\n',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );

      final reaped = await serviceOver(runner).reapOrphans('emulator-5554');
      expect(reaped, 3, reason: 'two processes and one forward');

      final commands = runner.requests.map((r) => r.arguments).toList();
      expect(
        commands,
        contains(
          equals([
            '-s',
            'emulator-5554',
            'shell',
            'kill',
            '-9',
            '11026',
            '11028',
          ]),
        ),
      );
      expect(
        commands,
        contains(
          equals(['-s', 'emulator-5554', 'forward', '--remove', 'tcp:57521']),
        ),
      );
    });

    test('a clean device is left completely alone', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      expect(await serviceOver(runner).reapOrphans('emulator-5554'), 0);
      // Only the two read-only queries.
      expect(runner.requests.length, 2);
    });
  });

  group('scrcpy-server deployment', () {
    // scrcpy-server 4.1 deletes its own jar as it starts (`unlinkSelf`), so one
    // fixed path meant the `control=true` attempt removed the jar the
    // `control=false` retry needed — `ClassNotFoundException`, SIGABRT.
    test('every session gets its own jar, under one reapable prefix', () {
      final first = scrcpyJarPathFor('3f3c4fef');
      final second = scrcpyJarPathFor('12a9795f');
      expect(first, isNot(second));
      expect(first, startsWith(kScrcpyJarPathPrefix));
      expect(second, startsWith(kScrcpyJarPathPrefix));
      // Never the plain name a developer's own scrcpy uses: reaping matches on
      // the prefix, and must not be able to kill someone else's session.
      expect(kScrcpyJarPathPrefix, isNot('/data/local/tmp/scrcpy-server'));
    });

    test('each tunnel attempt re-pushes, so the retry finds a jar', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('forward') &&
              request.arguments.contains('tcp:0')) {
            // A port nothing is listening on: every connect fails, so both
            // attempts run to exhaustion and `start` gives up.
            return const CommandResult(exitCode: 0, stdout: '1\n', stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final service = DeviceStreamService(
        adb: AdbService(runner: runner, sdk: _sdk()),
        runner: runner,
        serverBytes: () async => Uint8List(4),
        socketAttempts: 1,
        stagingDirectory: _staging(),
      );

      await expectLater(
        service.start('emulator-5554'),
        throwsA(isA<StateError>()),
      );

      final pushedTo = [
        for (final request in runner.requests)
          if (request.arguments.contains('push')) request.arguments.last,
      ];
      expect(
        pushedTo.length,
        2,
        reason: 'once for the control=true attempt, once for control=false',
      );
      expect(pushedTo.toSet().length, 2, reason: 'and never the same path');
      for (final path in pushedTo) {
        expect(path, startsWith(kScrcpyJarPathPrefix));
      }
    });

    test('a failed attempt takes its own jar off the device', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          if (request.arguments.contains('forward') &&
              request.arguments.contains('tcp:0')) {
            return const CommandResult(exitCode: 0, stdout: '1\n', stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      final service = DeviceStreamService(
        adb: AdbService(runner: runner, sdk: _sdk()),
        runner: runner,
        serverBytes: () async => Uint8List(4),
        socketAttempts: 1,
        stagingDirectory: _staging(),
      );
      await expectLater(
        service.start('emulator-5554'),
        throwsA(isA<StateError>()),
      );

      // A server that never started never unlinked itself, and 700 KB per
      // failed attempt in /data/local/tmp adds up.
      final removed = [
        for (final request in runner.requests)
          if (request.arguments.contains('rm')) request.arguments.last,
      ];
      expect(removed.length, 2);
      for (final path in removed) {
        expect(path, startsWith(kScrcpyJarPathPrefix));
      }
    });
  });

  group('host-side staging', () {
    // One fixed path in the system temp directory was shared by every start on
    // the machine *and by the tests*, which stage four dummy bytes there: a run
    // overlapping a live restart handed a real phone a 4-byte jar.
    test('two concurrent starts cannot reach each other\'s jar', () async {
      final staging = _staging();
      final live = <({String path, int length})>[];
      final dummy = <({String path, int length})>[];
      final liveRunner = _pushRecorder(live);
      final dummyRunner = _pushRecorder(dummy);

      DeviceStreamService serviceOver(FakeCommandRunner runner, int bytes) =>
          DeviceStreamService(
            adb: AdbService(runner: runner, sdk: _sdk()),
            runner: runner,
            serverBytes: () async => Uint8List(bytes),
            socketAttempts: 1,
            stagingDirectory: staging,
          );

      // A live session staging the real jar and a test staging its dummy,
      // interleaved — what a test run during a stream restart does.
      await Future.wait([
        expectLater(
          serviceOver(liveRunner, 700).start('F6IZLV6LMFT4U4ZT'),
          throwsA(isA<StateError>()),
        ),
        expectLater(
          serviceOver(dummyRunner, 4).start('emulator-5554'),
          throwsA(isA<StateError>()),
        ),
      ]);

      expect(live.map((p) => p.path).toSet(), hasLength(1));
      expect(dummy.map((p) => p.path).toSet(), hasLength(1));
      expect(
        live.first.path,
        isNot(dummy.first.path),
        reason: 'one path per start, never one for the machine',
      );
      // The bytes are the actual assertion: with the fixed path the live
      // session's second push carried the 4 dummy bytes.
      expect(live.map((p) => p.length), everyElement(700));
      expect(dummy.map((p) => p.length), everyElement(4));
    });

    test('the staged jar does not outlive the start that wrote it', () async {
      final staging = _staging();
      final pushes = <({String path, int length})>[];
      final runner = _pushRecorder(pushes);
      final service = DeviceStreamService(
        adb: AdbService(runner: runner, sdk: _sdk()),
        runner: runner,
        serverBytes: () async => Uint8List(700),
        socketAttempts: 1,
        stagingDirectory: staging,
      );

      await expectLater(
        service.start('emulator-5554'),
        throwsA(isA<StateError>()),
      );

      expect(pushes, hasLength(2), reason: 'it was staged and used');
      expect(_stagedNames(staging), isEmpty, reason: 'and then taken away');
    });

    test('stale staged jars are swept rather than accumulating', () async {
      final staging = _staging();
      File aged(String name) => File(
        '${staging.path}${Platform.pathSeparator}$name',
      )
        ..writeAsBytesSync(Uint8List(700))
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));

      // A start killed before its cleanup ran — the app quitting mid-start, a
      // crash — leaves one of these behind every time.
      final crashed = aged('karmashala-scrcpy-server-4.1-1a2b-0.jar');
      // What every build before this one left in the temp directory, once.
      final fixedPath = aged('karmashala-scrcpy-server-4.1.jar');
      final unrelated = aged('someone-elses-cache.jar');
      // Another start, still using its jar right now.
      final inFlight =
          File(
            '${staging.path}${Platform.pathSeparator}'
            'karmashala-scrcpy-server-4.1-inflight-0.jar',
          )..writeAsBytesSync(Uint8List(700));

      final pushes = <({String path, int length})>[];
      final runner = _pushRecorder(pushes);
      await expectLater(
        DeviceStreamService(
          adb: AdbService(runner: runner, sdk: _sdk()),
          runner: runner,
          serverBytes: () async => Uint8List(700),
          socketAttempts: 1,
          stagingDirectory: staging,
        ).start('emulator-5554'),
        throwsA(isA<StateError>()),
      );

      expect(crashed.existsSync(), isFalse);
      expect(fixedPath.existsSync(), isFalse, reason: 'the path this replaces');
      expect(
        unrelated.existsSync(),
        isTrue,
        reason: 'the sweep owns one prefix and nothing else in the temp dir',
      );
      expect(
        inFlight.existsSync(),
        isTrue,
        reason: 'age, not ownership: a live start\'s jar is seconds old',
      );
    });
  });

  group('DeviceStreamHealth', () {
    test('separates a dead stream from one nothing is decoding', () {
      // The two look identical on screen — a frozen picture — and have
      // completely different causes, so the distinction is carried explicitly.
      const noBytes = DeviceStreamHealth(
        state: DeviceStreamState.stalled,
        detail: 'No data from the device for 6s.',
      );
      const notDecoding = DeviceStreamHealth(
        state: DeviceStreamState.stalled,
        detail: 'still sending data but no frame has decoded',
        bytesArriving: true,
      );
      expect(noBytes.bytesArriving, isFalse);
      expect(notDecoding.bytesArriving, isTrue);
      expect(noBytes.isHealthy, isFalse);
      expect(notDecoding.isHealthy, isFalse);
    });

    test('carries what the server said, which is otherwise thrown away', () {
      const ended = DeviceStreamHealth(
        state: DeviceStreamState.ended,
        detail: 'scrcpy-server exited (code 143).',
        serverLog: ['Terminated'],
      );
      expect(ended.serverLog, ['Terminated']);
      expect(ended.isHealthy, isFalse);
    });

    test('a device with nothing new to show is healthy, and stays up', () {
      // Frame silence is what an untouched device looks like, so it is neither
      // unhealthy nor a reason to tear a working stream down.
      const idle = DeviceStreamHealth(
        state: DeviceStreamState.idle,
        detail: 'No screen changes for 20s.',
      );
      expect(idle.isHealthy, isTrue);
      expect(idle.needsRestart, isFalse);
      expect(
        const DeviceStreamHealth(
          state: DeviceStreamState.live,
          detail: 'Streaming.',
        ).isHealthy,
        isTrue,
      );
    });

    test('only a broken pipeline is worth a restart', () {
      for (final state in DeviceStreamState.values) {
        expect(
          DeviceStreamHealth(state: state, detail: '').needsRestart,
          state == DeviceStreamState.stalled ||
              state == DeviceStreamState.ended,
          reason: '$state',
        );
      }
    });
  });
}
