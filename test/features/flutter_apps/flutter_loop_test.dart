import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_loop.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_command_run.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_preflight.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

const String _appPubspec = '''
name: demo
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

const String _packagePubspec = '''
name: demo_plugin
dependencies:
  flutter:
    sdk: flutter
''';

const EnvironmentPath _wslProject = EnvironmentPath(
  environmentId: 'wsl:Ubuntu',
  path: '/home/me/app',
);

void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;
  late ProviderContainer container;

  /// A distribution that has its own Flutter, one Flutter app at the root and
  /// a resolved package cache — the ordinary case, so a test can change one
  /// thing about it.
  CommandResult healthy(CommandRequest request) {
    if (request.arguments.contains('exit 0')) {
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (request.arguments.contains('command -v flutter')) {
      return const CommandResult(
        exitCode: 0,
        stdout: '/home/me/flutter/bin/flutter\n',
        stderr: '',
      );
    }
    if (request.executable == '/home/me/flutter/bin/flutter') {
      return const CommandResult(
        exitCode: 0,
        stdout: 'Flutter 3.47.2 • channel stable\n',
        stderr: '',
      );
    }
    if (request.executable == 'find') {
      return const CommandResult(
        exitCode: 0,
        stdout: '/home/me/app/pubspec.yaml\n',
        stderr: '',
      );
    }
    if (request.executable == 'cat') {
      return const CommandResult(exitCode: 0, stdout: _appPubspec, stderr: '');
    }
    if (request.executable == 'test') {
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  void build({CommandResult Function(CommandRequest)? responder}) {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    runner = FakeCommandRunner(
      environmentId: 'wsl:Ubuntu',
      responder: responder ?? healthy,
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
  }

  setUp(build);
  tearDown(() {
    container.dispose();
    db.close();
  });

  FlutterLoopController loop() => container.read(flutterLoopProvider.notifier);

  group('the preflight, before anything is spawned', () {
    test('an environment nothing records is refused in the resolver\'s words',
        () async {
      final ready = await loop().readiness(
        const EnvironmentPath(environmentId: 'gone', path: '/x'),
        kind: FlutterCommandKind.pubGet,
      );
      expect(
        ready.preflight.problem,
        FlutterPreflightProblem.environmentUnresolved,
      );
      expect(ready.preflight.reason, contains('Unknown environment: gone'));
      expect(ready.preflight.reason, contains('Pick the checkout'));
      // Nothing was run on the way to that answer.
      expect(runner.requests, isEmpty);
    });

    test('the §17 refusal reaches the preflight whole', () async {
      build(
        responder: (request) => request.arguments.contains('command -v flutter')
            ? const CommandResult(
                exitCode: 0,
                stdout: '/mnt/c/Users/dlohani/flutter/bin/flutter\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final ready = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(ready.preflight.problem, FlutterPreflightProblem.noSdk);
      expect(ready.preflight.reason, contains('§17'));
      expect(ready.sdk!.isUsable, isFalse);
    });

    test('a directory with no Flutter pubspec names what would fix it',
        () async {
      build(
        responder: (request) => request.executable == 'find'
            ? const CommandResult(exitCode: 0, stdout: '', stderr: '')
            : healthy(request),
      );
      final ready = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(
        ready.preflight.problem,
        FlutterPreflightProblem.notAFlutterProject,
      );
      expect(ready.preflight.reason, contains('list_checkouts'));
    });

    test('a package is real Flutter and still refused for run', () async {
      build(
        responder: (request) => request.executable == 'cat'
            ? const CommandResult(
                exitCode: 0,
                stdout: _packagePubspec,
                stderr: '',
              )
            : healthy(request),
      );
      final forRun = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.run,
      );
      expect(forRun.preflight.problem, FlutterPreflightProblem.notRunnable);
      expect(forRun.preflight.reason, contains('package or a plugin'));

      // …and not refused for pub get, which a package does need.
      final forPubGet = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(forPubGet.preflight.isClear, isTrue);
    });

    test('no package_config blocks a run and never blocks pub get', () async {
      build(
        responder: (request) => request.executable == 'test'
            ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
            : healthy(request),
      );
      final forRun = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.run,
      );
      expect(forRun.preflight.problem, FlutterPreflightProblem.noPackages);
      expect(forRun.preflight.reason, contains('pubGet'));

      final forPubGet = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.pubGet,
      );
      expect(forPubGet.preflight.isClear, isTrue);
    });

    test('a package check that could not be taken does not block the run',
        () async {
      build(
        responder: (request) {
          if (request.executable == 'test') {
            throw CommandException('the distribution went away mid-check');
          }
          return healthy(request);
        },
      );
      final ready = await loop().readiness(
        _wslProject,
        kind: FlutterCommandKind.run,
      );
      // §19: our own blind spot is not evidence of an absence.
      expect(ready.preflight.isClear, isTrue);
    });
  });

  group('pub get, in a visible pane, in the checkout\'s own environment', () {
    test('the pane carries the located SDK, the argv and the distribution',
        () async {
      final outcome = await loop().pubGet(_wslProject);
      expect(outcome.preflight.isClear, isTrue);
      expect(outcome.run, isNotNull);

      final instance = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(outcome.run!.paneId)!;
      final launch = instance.agentLaunch!;
      expect(launch.executable, '/home/me/flutter/bin/flutter');
      expect(launch.arguments, ['pub', 'get']);
      expect(launch.workingDirectory, '/home/me/app');
      expect(launch.wslDistribution, 'Ubuntu');
      expect(launch.sshHostId, isNull);
      expect(launch.agentId, 'karmashala:flutter');
      expect(launch.title, 'pub get · demo');
    });

    test('the run is recorded with its command and the pane it lives in',
        () async {
      final outcome = await loop().pubGet(_wslProject);
      final run = container.read(flutterLoopProvider).single;
      expect(run.paneId, outcome.run!.paneId);
      expect(run.kind, FlutterCommandKind.pubGet);
      expect(run.environmentId, 'wsl:Ubuntu');
      expect(run.command, [
        '/home/me/flutter/bin/flutter',
        'pub',
        'get',
      ]);
      expect(
        loop().livenessOf(run.paneId),
        FlutterRunLiveness.running,
      );
    });

    test('a second pub get while one is live is refused, naming the pane',
        () async {
      final first = await loop().pubGet(_wslProject);
      final second = await loop().pubGet(_wslProject);
      expect(second.run, isNull);
      expect(second.preflight.problem, FlutterPreflightProblem.alreadyRunning);
      expect(second.preflight.reason, contains(first.run!.paneId));
      expect(container.read(flutterLoopProvider), hasLength(1));
    });

    test('a refused preflight opens no pane at all', () async {
      final outcome = await loop().pubGet(
        const EnvironmentPath(environmentId: 'gone', path: '/x'),
      );
      expect(outcome.run, isNull);
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    });

    test('a pane the terminal no longer knows reads unknown, never finished',
        () {
      expect(loop().livenessOf('never-opened'), FlutterRunLiveness.unknown);
    });
  });
}
