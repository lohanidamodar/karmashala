import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_sdk_readings.dart';
import 'package:karmashala/src/features/flutter_apps/data/flutter_sdk_service.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_sdk.dart';

import '../../support/fake_command_runner.dart';

final DateTime _now = DateTime.utc(2026, 9, 8, 12);

ExecutionEnvironment _environment(EnvironmentKind kind, {String name = 'Ubuntu'}) =>
    ExecutionEnvironment(
      id: 'env',
      kind: kind,
      name: name,
      wslDistribution: kind == EnvironmentKind.wsl ? 'Ubuntu' : null,
      createdAt: _now,
    );

void main() {
  group('flutterExecutableFor — CLAUDE.md §17 as code', () {
    test('Windows names the .bat and never the extensionless script', () {
      expect(flutterExecutableFor(EnvironmentKind.windowsNative), 'flutter.bat');
    });

    test('every POSIX kind names plain flutter', () {
      for (final kind in const [
        EnvironmentKind.localPosix,
        EnvironmentKind.wsl,
        EnvironmentKind.ssh,
      ]) {
        expect(flutterExecutableFor(kind), 'flutter');
      }
    });
  });

  group('windowsInstallRefusal', () {
    test('a WSL flutter under /mnt/c is refused, and the reason names §17', () {
      final refusal = windowsInstallRefusal(
        EnvironmentKind.wsl,
        '/mnt/c/Users/dlohani/flutter/bin/flutter',
      );
      expect(refusal, isNotNull);
      expect(refusal, contains('/mnt/c/Users/dlohani/flutter/bin/flutter'));
      expect(refusal, contains('§17'));
      expect(refusal, contains('Install Flutter inside the distribution'));
    });

    test('any drive letter, upper or lower', () {
      expect(windowsInstallRefusal(EnvironmentKind.wsl, '/mnt/d/flutter/bin/flutter'),
          isNotNull);
      expect(windowsInstallRefusal(EnvironmentKind.wsl, '/mnt/C/flutter/bin/flutter'),
          isNotNull);
    });

    test("the distribution's own flutter is not refused", () {
      expect(
        windowsInstallRefusal(EnvironmentKind.wsl, '/home/me/flutter/bin/flutter'),
        isNull,
      );
      expect(
        windowsInstallRefusal(EnvironmentKind.wsl, '/mnt-of-mine/flutter'),
        isNull,
      );
    });

    test('only WSL is judged this way — no other kind has a drive mount', () {
      for (final kind in const [
        EnvironmentKind.windowsNative,
        EnvironmentKind.localPosix,
        EnvironmentKind.ssh,
      ]) {
        expect(windowsInstallRefusal(kind, '/mnt/c/flutter/bin/flutter'), isNull);
      }
    });
  });

  group('FlutterSdkReading', () {
    test('a reading with no executable is not usable', () {
      final reading = FlutterSdkReading.refused(
        environmentId: 'env',
        readAt: _now,
        refusal: FlutterSdkRefusal.notFound,
        reason: 'nothing here',
      );
      expect(reading.isUsable, isFalse);
      expect(reading.toJson()['refusal'], 'notFound');
    });

    test('freshness is measured from the reading, not from a cadence', () {
      final reading = FlutterSdkReading(
        environmentId: 'env',
        readAt: _now,
        executable: 'flutter.bat',
      );
      expect(reading.isFreshAt(_now.add(const Duration(hours: 11))), isTrue);
      expect(reading.isFreshAt(_now.add(const Duration(hours: 13))), isFalse);
      expect(reading.isUsable, isTrue);
    });
  });

  group('FlutterSdkService', () {
    late FakeCommandRunner runner;

    setUp(() => runner = FakeCommandRunner(environmentId: 'env'));

    Future<FlutterSdkReading> read(EnvironmentKind kind, {String name = 'Ubuntu'}) =>
        FlutterSdkService(
          runner: runner,
          environment: _environment(kind, name: name),
        ).read(_now);

    test('Windows: located with where flutter.bat, version parsed', () async {
      runner.responder = (request) {
        if (request.executable == 'where') {
          return const CommandResult(
            exitCode: 0,
            stdout: r'C:\Users\dlohani\flutter\bin\flutter.bat' '\n',
            stderr: '',
          );
        }
        return const CommandResult(
          exitCode: 0,
          stdout: 'Flutter 3.38.5 • channel stable • https://github.com/flutter/flutter.git\n',
          stderr: '',
        );
      };
      final reading = await read(EnvironmentKind.windowsNative, name: 'Windows');
      expect(reading.isUsable, isTrue);
      expect(reading.executable, r'C:\Users\dlohani\flutter\bin\flutter.bat');
      expect(reading.version, '3.38.5');
      expect(reading.readAt, _now);
      expect(runner.requests.first.arguments, ['flutter.bat']);
    });

    test('the WSL trap: located under /mnt/c and NOTHING is spawned at it',
        () async {
      runner.responder = (request) {
        if (request.arguments.contains('exit 0')) {
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        return const CommandResult(
          exitCode: 0,
          stdout: '/mnt/c/Users/dlohani/flutter/bin/flutter\n',
          stderr: '',
        );
      };
      final reading = await read(EnvironmentKind.wsl);
      expect(reading.refusal, FlutterSdkRefusal.windowsInstallOnPosixPath);
      expect(reading.isUsable, isFalse);
      expect(reading.reason, contains('§17'));
      // The reachability probe and the lookup, and no third call: the version
      // probe would have been the run that does the damage.
      expect(runner.requests, hasLength(2));
      expect(
        runner.requests.any(
          (request) => request.executable.contains('/mnt/c/'),
        ),
        isFalse,
      );
    });

    test('an unreachable distribution is unknown, never "no Flutter"', () async {
      runner.responder = (request) => request.arguments.contains('exit 0')
          ? const CommandResult(exitCode: 1, stdout: '', stderr: 'not running')
          : const CommandResult(exitCode: 0, stdout: '/usr/bin/flutter', stderr: '');
      final reading = await read(EnvironmentKind.wsl);
      expect(reading.refusal, FlutterSdkRefusal.environmentUnreachable);
      expect(reading.reason, contains('unknown rather than no'));
      // It stopped at the reachability probe rather than concluding from a
      // lookup that could not have answered.
      expect(runner.requests, hasLength(1));
    });

    test('nothing on PATH names the fix', () async {
      runner.responder = (request) => request.arguments.contains('exit 0')
          ? const CommandResult(exitCode: 0, stdout: '', stderr: '')
          : const CommandResult(exitCode: 1, stdout: '', stderr: '');
      final reading = await read(EnvironmentKind.wsl);
      expect(reading.refusal, FlutterSdkRefusal.notFound);
      expect(reading.reason, contains('No Flutter SDK is on PATH in Ubuntu'));
      expect(reading.reason, contains('Install one'));
    });

    test('the local host is not asked to prove it exists', () async {
      runner.responder = (_) => const CommandResult(
        exitCode: 0,
        stdout: '/usr/local/bin/flutter\n',
        stderr: '',
      );
      await read(EnvironmentKind.localPosix, name: 'macOS');
      expect(
        runner.requests.any((request) => request.arguments.contains('exit 0')),
        isFalse,
      );
    });

    test('a version that will not read leaves the path usable and the number null',
        () async {
      runner.responder = (request) {
        if (request.executable.endsWith('flutter')) {
          return const CommandResult(exitCode: 2, stdout: '', stderr: 'boom');
        }
        return const CommandResult(
          exitCode: 0,
          stdout: '/usr/local/bin/flutter\n',
          stderr: '',
        );
      };
      final reading = await read(EnvironmentKind.localPosix, name: 'macOS');
      expect(reading.isUsable, isTrue);
      expect(reading.version, isNull);
    });

    test('an environment that throws is unreachable, not empty', () async {
      runner.throwError = CommandException('no connection pool');
      final reading = await read(EnvironmentKind.ssh, name: 'build-box');
      expect(reading.refusal, FlutterSdkRefusal.environmentUnreachable);
      expect(reading.reason, contains('no connection pool'));
    });
  });

  group('FlutterSdkReadings', () {
    late _MovableClock clock;
    late FakeCommandRunner runner;
    late ProviderContainer container;

    setUp(() {
      clock = _MovableClock(_now);
      runner = FakeCommandRunner(environmentId: 'env')
        ..responder = (request) => request.arguments.contains('exit 0')
            ? const CommandResult(exitCode: 0, stdout: '', stderr: '')
            : const CommandResult(
                exitCode: 0,
                stdout: '/usr/local/bin/flutter\nFlutter 3.38.5\n',
                stderr: '',
              );
      container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(clock),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    FlutterSdkReadings readings() =>
        container.read(flutterSdkReadingsProvider.notifier);

    test('nothing has been looked at until somebody asks', () {
      expect(container.read(flutterSdkReadingsProvider), isEmpty);
      expect(readings().cached('env'), isNull);
    });

    test('a fresh reading is reused rather than re-measured', () async {
      final environment = _environment(EnvironmentKind.localPosix, name: 'macOS');
      await readings().readFor(environment);
      final calls = runner.requests.length;
      clock.now = _now.add(const Duration(hours: 11));
      await readings().readFor(environment);
      expect(runner.requests, hasLength(calls));
    });

    test('a reading that has aged out is taken again', () async {
      final environment = _environment(EnvironmentKind.localPosix, name: 'macOS');
      await readings().readFor(environment);
      final calls = runner.requests.length;
      clock.now = _now.add(const Duration(hours: 13));
      final again = await readings().readFor(environment);
      expect(runner.requests.length, greaterThan(calls));
      expect(again.readAt, clock.now);
    });

    test('force looks again however fresh the last answer was', () async {
      final environment = _environment(EnvironmentKind.localPosix, name: 'macOS');
      await readings().readFor(environment);
      final calls = runner.requests.length;
      await readings().readFor(environment, force: true);
      expect(runner.requests.length, greaterThan(calls));
    });

    test('forget makes the next ask measure', () async {
      final environment = _environment(EnvironmentKind.localPosix, name: 'macOS');
      await readings().readFor(environment);
      expect(readings().cached('env'), isNotNull);
      readings().forget('env');
      expect(readings().cached('env'), isNull);
    });
  });
}

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}
