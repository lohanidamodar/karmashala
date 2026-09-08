import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_sdk_readings.dart';
import 'package:karmashala/src/features/flutter_apps/data/flutter_sdk_service.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_sdk.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';

/// **A Flutter SDK a person names for one environment.**
///
/// The loop refuses in words when nothing named `flutter` is on an
/// environment's PATH — the right refusal, and it was the whole answer.
/// Somebody whose SDK is unpacked somewhere PATH does not mention had no row
/// to say so.
///
/// Two rules make this more than a text field, and both are §20's:
///
/// * the hand-set path is read **before** the PATH probe, and PATH is then not
///   asked at all — a fallback that quietly finds something else is how a user
///   comes to believe their answer is being used when it is not;
/// * no measurement or sweep may overrule it, which here is structural rather
///   than remembered: discovery writes `execution_environments`, and this is
///   kept in `Settings`, which discovery never touches.
///
/// And §17 applies to a typed path exactly as it does to a located one: a
/// person can type `/mnt/c/…/flutter` as easily as WSL's PATH can resolve to
/// it, and running it is the same disaster.
final DateTime _now = DateTime.utc(2026, 9, 9, 12);

ExecutionEnvironment _environment(
  EnvironmentKind kind, {
  String name = 'Ubuntu',
}) => ExecutionEnvironment(
  id: 'env',
  kind: kind,
  name: name,
  wslDistribution: kind == EnvironmentKind.wsl ? 'Ubuntu' : null,
  createdAt: _now,
);

void main() {
  group('FlutterSdkService, given a hand-set path', () {
    late FakeCommandRunner runner;

    setUp(() {
      runner = FakeCommandRunner(environmentId: 'env')
        ..responder = (request) => const CommandResult(
          exitCode: 0,
          stdout: 'Flutter 3.38.5 • channel stable\n',
          stderr: '',
        );
    });

    Future<FlutterSdkReading> read(
      EnvironmentKind kind, {
      String name = 'Ubuntu',
      String? path,
    }) => FlutterSdkService(
      runner: runner,
      environment: _environment(kind, name: name),
      handSetExecutable: path,
    ).read(_now);

    test('it is used, and PATH is never asked', () async {
      final reading = await read(
        EnvironmentKind.windowsNative,
        name: 'Windows',
        path: r'D:\sdk\flutter\bin\flutter.bat',
      );
      expect(reading.isUsable, isTrue);
      expect(reading.executable, r'D:\sdk\flutter\bin\flutter.bat');
      expect(reading.version, '3.38.5');
      // One call, and it is the version probe. `where flutter.bat` never ran:
      // a lookup that could contradict the person's own answer is a lookup
      // this must not make.
      expect(runner.requests, hasLength(1));
      expect(
        runner.requests.single.executable,
        r'D:\sdk\flutter\bin\flutter.bat',
      );
      expect(
        runner.requests.any((request) => request.executable == 'where'),
        isFalse,
      );
    });

    test('blank is not a path — PATH answers again', () async {
      runner.responder = (request) => request.executable == 'where'
          ? const CommandResult(
              exitCode: 0,
              stdout: 'C:\\found\\flutter.bat\n',
              stderr: '',
            )
          : const CommandResult(
              exitCode: 0,
              stdout: 'Flutter 3.1.0',
              stderr: '',
            );
      final reading = await read(
        EnvironmentKind.windowsNative,
        name: 'Windows',
        path: '   ',
      );
      expect(reading.executable, 'C:\\found\\flutter.bat');
      expect(
        runner.requests.any((request) => request.executable == 'where'),
        isTrue,
      );
    });

    test('the §17 trap is refused when typed, and NOTHING is spawned at it',
        () async {
      runner.responder = (request) =>
          const CommandResult(exitCode: 0, stdout: '', stderr: '');
      final reading = await read(
        EnvironmentKind.wsl,
        path: '/mnt/c/Users/dlohani/flutter/bin/flutter',
      );
      expect(reading.refusal, FlutterSdkRefusal.windowsInstallOnPosixPath);
      expect(reading.reason, contains('§17'));
      // The danger is identical to a located path's; where the path came from
      // is not, and the sentence must not claim PATH resolved something the
      // person typed.
      expect(reading.reason, contains('The Flutter SDK path set for'));
      expect(reading.reason, isNot(contains("distribution's PATH is")));
      expect(reading.reason, contains('clear it'));
      expect(reading.reason, isNot(contains('Install Flutter inside')));
      // The reachability probe, and nothing else. The version probe would have
      // been the run that swaps a Linux dart-sdk into the Windows install.
      expect(runner.requests, hasLength(1));
      expect(
        runner.requests.any((request) => request.executable.contains('/mnt/c/')),
        isFalse,
      );
    });

    test('an unreachable environment is still unknown, not a bad path',
        () async {
      runner.responder = (request) => request.arguments.contains('exit 0')
          ? const CommandResult(exitCode: 1, stdout: '', stderr: 'not running')
          : const CommandResult(
              exitCode: 0,
              stdout: 'Flutter 3.38.5',
              stderr: '',
            );
      final reading = await read(
        EnvironmentKind.wsl,
        path: '/home/me/flutter/bin/flutter',
      );
      expect(reading.refusal, FlutterSdkRefusal.environmentUnreachable);
      expect(runner.requests, hasLength(1));
    });

    test('a path that will not run names the row, not the PATH', () async {
      runner.throwError = CommandException('No such file or directory');
      final reading = await read(
        EnvironmentKind.localPosix,
        name: 'macOS',
        path: '/opt/flutter/bin/flutter',
      );
      expect(reading.refusal, FlutterSdkRefusal.handSetUnusable);
      expect(reading.isUsable, isFalse);
      expect(reading.reason, contains('/opt/flutter/bin/flutter'));
      expect(reading.reason, contains('No such file or directory'));
      // The fix is the row, and the sentence names it and both ways out.
      expect(reading.reason, contains('Settings'));
      expect(reading.reason, contains('clear it'));
      // Never `notFound`: "install one there" is the wrong advice for a
      // machine that has one and was told where.
      expect(reading.reason, isNot(contains('Install one')));
    });

    test('a version that will not read leaves the hand-set path usable',
        () async {
      runner.responder = (request) =>
          const CommandResult(exitCode: 2, stdout: '', stderr: 'boom');
      final reading = await read(
        EnvironmentKind.localPosix,
        name: 'macOS',
        path: '/opt/flutter/bin/flutter',
      );
      expect(reading.isUsable, isTrue);
      expect(reading.version, isNull);
    });

    test('with nothing set, the PATH probe is exactly what it always was',
        () async {
      runner.responder = (request) => request.executable == 'where'
          ? const CommandResult(
              exitCode: 0,
              stdout: 'C:\\found\\flutter.bat\n',
              stderr: '',
            )
          : const CommandResult(
              exitCode: 0,
              stdout: 'Flutter 3.1.0',
              stderr: '',
            );
      final reading = await read(EnvironmentKind.windowsNative, name: 'Windows');
      expect(reading.executable, 'C:\\found\\flutter.bat');
      expect(runner.requests.first.arguments, ['flutter.bat']);
    });
  });

  group('Settings holds the answer, keyed by environment', () {
    test('it round-trips through the stored JSON', () {
      const settings = Settings();
      final set = settings.withFlutterSdkPath(
        'wsl:Ubuntu',
        '/home/me/flutter/bin/flutter',
      );
      expect(set.flutterSdkPathFor('wsl:Ubuntu'), '/home/me/flutter/bin/flutter');
      final back = Settings.fromJson(set.toJson());
      expect(back.flutterSdkPathFor('wsl:Ubuntu'), '/home/me/flutter/bin/flutter');
      expect(back, set);
    });

    test('one environment says nothing about another', () {
      // §17 is the reason this is per environment and not one path: a Windows
      // SDK is exactly the wrong answer inside a distribution.
      final set = const Settings().withFlutterSdkPath(
        'windows',
        r'C:\src\flutter\bin\flutter.bat',
      );
      expect(set.flutterSdkPathFor('wsl:Ubuntu'), isNull);
    });

    test('blank takes the answer back, and PATH answers again', () {
      final set = const Settings().withFlutterSdkPath('env', '/opt/flutter');
      expect(set.withFlutterSdkPath('env', '  ').flutterSdkPathFor('env'), isNull);
      expect(set.withFlutterSdkPath('env', null).flutterSdkPathFor('env'), isNull);
      // Removed, not stored as an empty string: absence is the answer, and a
      // stored `' '` would be a path refused for ever with nothing on screen
      // to explain why.
      expect(
        set.withFlutterSdkPath('env', '').toJson().containsKey('flutterSdkPaths'),
        isFalse,
      );
    });

    test('a stray space is not part of a path', () {
      expect(
        const Settings()
            .withFlutterSdkPath('env', '  /opt/flutter/bin/flutter  ')
            .flutterSdkPathFor('env'),
        '/opt/flutter/bin/flutter',
      );
    });

    test('an unreadable entry is skipped rather than becoming a bad path', () {
      final back = Settings.fromJson(const {
        'flutterSdkPaths': {'env': 7, 'other': '', 'good': '/opt/flutter'},
      });
      expect(back.flutterSdkPathFor('env'), isNull);
      expect(back.flutterSdkPathFor('other'), isNull);
      expect(back.flutterSdkPathFor('good'), '/opt/flutter');
    });
  });

  group('the setting reaches the reading, and invalidates the old one', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeCommandRunner runner;

    setUp(() {
      db = AppDatabase.memory();
      runner = FakeCommandRunner(environmentId: 'env')
        ..responder = (request) => request.executable == 'where'
            ? const CommandResult(
                exitCode: 0,
                stdout: 'C:\\on\\path\\flutter.bat\n',
                stderr: '',
              )
            : const CommandResult(
                exitCode: 0,
                stdout: 'Flutter 3.38.5',
                stderr: '',
              );
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(_now)),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
    });

    test('a saved path is what the next reading measures', () async {
      final environment = _environment(
        EnvironmentKind.windowsNative,
        name: 'Windows',
      );
      final readings = container.read(flutterSdkReadingsProvider.notifier);

      final onPath = await readings.readFor(environment);
      expect(onPath.executable, 'C:\\on\\path\\flutter.bat');

      container
          .read(settingsControllerProvider.notifier)
          .setFlutterSdkPath('env', r'D:\sdk\flutter\bin\flutter.bat');
      // A reading taken against the old answer must not be shown beside the
      // new one, and this is what makes the next ask measure rather than
      // answering from the cache — the reading is still fresh by the clock.
      expect(readings.cached('env'), isNull);

      final handSet = await readings.readFor(environment);
      expect(handSet.executable, r'D:\sdk\flutter\bin\flutter.bat');
    });

    test('clearing it puts the environment back on PATH', () async {
      final environment = _environment(
        EnvironmentKind.windowsNative,
        name: 'Windows',
      );
      final settings = container.read(settingsControllerProvider.notifier)
        ..setFlutterSdkPath('env', r'D:\sdk\flutter\bin\flutter.bat');
      final readings = container.read(flutterSdkReadingsProvider.notifier);
      expect(
        (await readings.readFor(environment)).executable,
        r'D:\sdk\flutter\bin\flutter.bat',
      );

      settings.setFlutterSdkPath('env', '');
      expect(
        (await readings.readFor(environment)).executable,
        'C:\\on\\path\\flutter.bat',
      );
    });

    test('the setting survives a reload, so discovery cannot outlive it',
        () async {
      container
          .read(settingsControllerProvider.notifier)
          .setFlutterSdkPath('env', r'D:\sdk\flutter\bin\flutter.bat');
      // A second container over the same database is the launch that would
      // have re-run discovery. It reads the same answer back.
      final reopened = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(reopened.dispose);
      expect(
        reopened.read(settingsControllerProvider).flutterSdkPathFor('env'),
        r'D:\sdk\flutter\bin\flutter.bat',
      );
    });
  });
}
