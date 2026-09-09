import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_gate_observer.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_loop.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';

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

const EnvironmentPath _project = EnvironmentPath(
  environmentId: 'wsl:Ubuntu',
  path: '/home/me/app',
);

/// `flutter analyze` and `flutter test` as checks the app runs and records.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late Directory artifacts;

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
    if (request.executable == 'find') {
      return CommandResult(
        exitCode: 0,
        stdout: '${request.arguments.first}/pubspec.yaml\n',
        stderr: '',
      );
    }
    if (request.executable == 'cat') {
      return const CommandResult(exitCode: 0, stdout: _appPubspec, stderr: '');
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  setUp(() {
    artifacts = Directory.systemTemp.createTempSync('karmashala-gate-test');
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              environmentId: 'wsl:Ubuntu',
              responder: healthy,
            ),
          ),
        ),
        verificationRootProvider.overrideWithValue(artifacts),
      ],
    );
    // Watched, not read: the observer's own subscription is paused otherwise,
    // which is the failure its doc warns about.
    container.listen(flutterGateObserverProvider, (_, _) {});
  });

  tearDown(() {
    container.dispose();
    db.close();
    if (artifacts.existsSync()) artifacts.deleteSync(recursive: true);
  });

  FlutterLoopController loop() => container.read(flutterLoopProvider.notifier);

  /// Everything the pane exit set off has been written.
  Future<void> settle() =>
      container.read(flutterGateObserverProvider.notifier).drain();

  FakeTerminalInstance paneOf(String paneId) =>
      container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId)!
          as FakeTerminalInstance;

  List<VerificationRun> recorded() =>
      container.read(verificationServiceProvider).list();

  test('analyze runs the located SDK in the checkout, in a visible pane',
      () async {
    final outcome = await loop().gate(_project, FlutterCommandKind.analyze);
    expect(outcome.preflight.isClear, isTrue);
    final launch = paneOf(outcome.run!.paneId).agentLaunch!;
    expect(launch.executable, '/home/me/flutter/bin/flutter');
    expect(launch.arguments, ['analyze']);
    expect(launch.workingDirectory, '/home/me/app');
    expect(launch.wslDistribution, 'Ubuntu');
    expect(launch.title, 'analyze · demo');
  });

  test('extra arguments are the caller\'s, and go after the verb', () async {
    final outcome = await loop().gate(
      _project,
      FlutterCommandKind.test,
      extraArguments: const ['--exclude-tags=live-ssh,live-wsl'],
    );
    expect(paneOf(outcome.run!.paneId).agentLaunch!.arguments, [
      'test',
      '--exclude-tags=live-ssh,live-wsl',
    ]);
  });

  test('a green gate becomes a recorded pass when its process stops', () async {
    final outcome = await loop().gate(_project, FlutterCommandKind.analyze);
    final paneId = outcome.run!.paneId;
    paneOf(paneId).terminal.write('No issues found! (ran in 9.1s)\r\n');
    paneOf(paneId).exitWith(0);
    await settle();

    final run = recorded().single;
    expect(run.verdict, VerificationVerdict.pass);
    expect(run.title, 'flutter analyze · /home/me/app');
    expect(loop().byPane(paneId)!.verificationRunId, run.id);
    expect(loop().byPane(paneId)!.exitCode, 0);
  });

  test('a failing gate records the fail and keeps what it printed', () async {
    final outcome = await loop().gate(_project, FlutterCommandKind.test);
    final paneId = outcome.run!.paneId;
    paneOf(paneId).terminal.write('00:12 +41 -1: Some tests failed.\r\n');
    paneOf(paneId).exitWith(1);
    await settle();

    final run = recorded().single;
    expect(run.verdict, VerificationVerdict.fail);
    expect(run.reason, contains('exited 1'));
    final artifact = File(
      '${run.artifactDirectory}${Platform.pathSeparator}'
      '${run.artifacts.single.relativePath}',
    );
    expect(artifact.readAsStringSync(), contains('Some tests failed'));
  });

  test('pub get and run are not checks and record nothing', () async {
    final outcome = await loop().pubGet(_project);
    paneOf(outcome.run!.paneId).exitWith(0);
    await settle();
    expect(recorded(), isEmpty);
    // The exit is still noted on the run: it is history, just not a verdict.
    expect(loop().byPane(outcome.run!.paneId)!.exitCode, 0);
  });

  test('a pane that is not ours is ignored, silently', () async {
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tabId = controller.openTab(TerminalProfile.powerShell);
    final state = container.read(terminalSessionsControllerProvider);
    final paneId = state.tabs
        .firstWhere((tab) => tab.id == tabId)
        .layout
        .panes
        .single;
    paneOf(paneId).exitWith(1);
    await settle();
    expect(recorded(), isEmpty);
  });

  test('a second gate of the same kind while one is live is refused', () async {
    final first = await loop().gate(_project, FlutterCommandKind.analyze);
    final second = await loop().gate(_project, FlutterCommandKind.analyze);
    expect(second.run, isNull);
    expect(second.preflight.problem, FlutterPreflightProblem.alreadyRunning);
    expect(second.preflight.reason, contains(first.run!.paneId));
  });

  test('analyze and test do not block each other', () async {
    await loop().gate(_project, FlutterCommandKind.analyze);
    final other = await loop().gate(_project, FlutterCommandKind.test);
    expect(other.run, isNotNull);
  });

  test('a gate whose verdict could not be written does not stop the next one',
      () async {
    // A *file* where the artifact root should be, so creating the run's
    // directory under it throws. Deleting the directory would not do: the
    // store creates it recursively and would simply put it back.
    artifacts.deleteSync(recursive: true);
    File(artifacts.path).writeAsStringSync('not a directory');
    final broken = await loop().gate(_project, FlutterCommandKind.analyze);
    paneOf(broken.run!.paneId).exitWith(1);
    await settle();
    expect(recorded(), isEmpty);

    // An errored queue would swallow every exit after it, silently.
    File(artifacts.path).deleteSync();
    artifacts.createSync(recursive: true);
    final next = await loop().gate(_project, FlutterCommandKind.test);
    paneOf(next.run!.paneId).exitWith(0);
    await settle();
    expect(recorded(), hasLength(1));
    expect(recorded().single.verdict, VerificationVerdict.pass);
  });
}
