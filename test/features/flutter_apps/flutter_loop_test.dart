import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/flutter_apps/application/attached_apps.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_loop.dart';
import 'package:karmashala/src/features/flutter_apps/data/vm_service_uri_directory.dart';
import 'package:karmashala/src/features/flutter_apps/domain/attached_app.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_command_run.dart';
import 'package:karmashala/src/features/flutter_apps/domain/flutter_preflight.dart';
import 'package:karmashala/src/features/flutter_apps/domain/vm_service_out_file.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'fake_vm_service.dart';

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
  late Directory vmDirectory;
  late Map<String, FakeVmService> reachable;

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
      // The root asked about, so a second project in the same distribution is
      // a second answer rather than the first one again.
      return CommandResult(
        exitCode: 0,
        stdout: '${request.arguments.first}/pubspec.yaml\n',
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
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
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
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        flutterAppDiscoveryDirectoryProvider.overrideWith(
          (ref) async => VmServiceUriDirectory(vmDirectory),
        ),
        vmServiceConnectorProvider.overrideWithValue((uri) async {
          final fake = reachable[uri.toString()];
          if (fake == null) throw const _Refused();
          return fake.client;
        }),
      ],
    );
  }

  setUp(() {
    vmDirectory = Directory.systemTemp.createTempSync('karmashala-loop-test');
    reachable = <String, FakeVmService>{};
    build();
  });
  tearDown(() {
    container.dispose();
    db.close();
    if (vmDirectory.existsSync()) vmDirectory.deleteSync(recursive: true);
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

  group('flutter run, and the auto-attach', () {
    const address = 'http://127.0.0.1:53119/tok=/';
    const wsAddress = 'ws://127.0.0.1:53119/tok=/ws';

    void serve() => reachable[wsAddress] = FakeVmService();

    test('the pane carries -d, the device, and the out-file for its kind',
        () async {
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      expect(outcome.preflight.isClear, isTrue);
      final run = outcome.run!;
      final expectedOutFile = vmServiceOutFileFor(
        kind: EnvironmentKind.wsl,
        directory: vmDirectory.path,
        name: vmServiceOutFileName('demo', 'id-0'),
      );
      expect(run.vmServiceOutFile, expectedOutFile);
      expect(run.deviceId, 'emulator-5554');

      final launch = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(run.paneId)!
          .agentLaunch!;
      expect(launch.arguments.take(3), ['run', '-d', 'emulator-5554']);
      if (expectedOutFile != null) {
        expect(
          launch.arguments,
          contains('--vmservice-out-file=$expectedOutFile'),
        );
      } else {
        expect(
          launch.arguments.any((a) => a.startsWith('--vmservice-out-file')),
          isFalse,
        );
      }
    });

    test('extra arguments land after the ones this app spells', () async {
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
        extraArguments: const ['--profile'],
      );
      final launch = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(outcome.run!.paneId)!
          .agentLaunch!;
      expect(launch.arguments.last, '--profile');
    });

    test('the address the pane printed attaches it, with nobody calling '
        'flutter_attach', () async {
      serve();
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      final paneId = outcome.run!.paneId;
      final instance = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId)!;

      expect(loop().byPane(paneId)!.vmServiceUri, isNull);
      instance.terminal.write(
        'Launching lib/main.dart on sdk gphone64 x86 64 in debug mode...\r\n'
        'A Dart VM Service on sdk gphone64 x86 64 is available at:\r\n'
        '$address\r\n',
      );
      // The listener fires synchronously; the attach it starts does not.
      await Future<void>.delayed(Duration.zero);

      final run = loop().byPane(paneId)!;
      expect(run.vmServiceUri, wsAddress);
      expect(run.appId, AttachedApp.idFor(Uri.parse(wsAddress)));
      expect(run.isAttached, isTrue);
      expect(
        container.read(attachedAppsProvider).byId(run.appId!)!.reachability,
        AppReachability.attached,
      );
    });

    test('the DevTools line alone attaches nothing', () async {
      serve();
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      final instance = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(outcome.run!.paneId)!;
      instance.terminal.write(
        'The Flutter DevTools debugger and profiler on sdk gphone64 is '
        'available at: http://127.0.0.1:9101?uri=$address\r\n',
      );
      await Future<void>.delayed(Duration.zero);
      expect(loop().byPane(outcome.run!.paneId)!.vmServiceUri, isNull);
    });

    test('refresh reads the file flutter run wrote, when there is one',
        () async {
      serve();
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      final run = outcome.run!;
      final path = hostSpellingOfOutFile(run.vmServiceOutFile ?? '');
      if (path == null) return; // No file on this host; the pane is the route.
      File(path).writeAsStringSync(wsAddress);

      final refreshed = await loop().refresh(run.paneId);
      expect(refreshed!.vmServiceUri, wsAddress);
      expect(refreshed.isAttached, isTrue);
    });

    test('an address nothing answers on keeps the address and reports it',
        () async {
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      final instance = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(outcome.run!.paneId)!;
      instance.terminal.write(
        'A Dart VM Service on X is available at: $address\r\n',
      );
      await Future<void>.delayed(Duration.zero);
      final run = loop().byPane(outcome.run!.paneId)!;
      expect(run.vmServiceUri, wsAddress);
      expect(
        container.read(attachedAppsProvider).byId(run.appId!)!.reachability,
        AppReachability.unreachable,
      );
    });

    test('one run per device: the second is refused naming the first pane',
        () async {
      final first = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      final second = await loop().run(
        project: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/other',
        ),
        deviceId: 'emulator-5554',
      );
      expect(second.run, isNull);
      expect(second.preflight.problem, FlutterPreflightProblem.alreadyRunning);
      expect(second.preflight.reason, contains(first.run!.paneId));
    });

    test("another session's claim refuses the launch in the claim's words",
        () async {
      SessionDao(db).insert(session(id: 's1', title: 'Fixing the list'));
      SessionDao(db).insert(session(id: 's2', title: 'Something else'));
      final held = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
        sessionId: 's1',
      );
      expect(held.run, isNotNull);
      await loop().stop(held.run!.paneId);

      final blocked = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
        sessionId: 's2',
      );
      expect(blocked.run, isNull);
      expect(blocked.preflight.problem, FlutterPreflightProblem.deviceBusy);
      expect(blocked.preflight.reason, contains('Fixing the list'));
      expect(blocked.preflight.reason, contains('device_screenshot'));
    });

    test('stop ends the process rather than detaching it', () async {
      final outcome = await loop().run(
        project: _wslProject,
        deviceId: 'emulator-5554',
      );
      final paneId = outcome.run!.paneId;
      final stopped = await loop().stop(paneId);
      expect(stopped!.endedAt, isNotNull);
      expect(
        container.read(terminalSessionsControllerProvider).livenessOf(paneId),
        isNot(PaneLiveness.live),
      );
    });

    test('stopping a pane this app never opened is null, not a throw', () async {
      expect(await loop().stop('someone-elses-pane'), isNull);
    });
  });
}

/// The connector's refusal, shaped like a real one.
class _Refused implements Exception {
  const _Refused();
  @override
  String toString() => 'nothing is listening there';
}
