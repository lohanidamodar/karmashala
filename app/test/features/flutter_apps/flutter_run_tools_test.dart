import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_gate_observer.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_run_tools.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';

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

/// The agent's door onto the loop: run, stop, status, and the three that make
/// the loop closable.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late Directory artifacts;
  late CommandResult Function(CommandRequest) responder;

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
    responder = healthy;
    artifacts = Directory.systemTemp.createTempSync('karmashala-tools-test');
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(
      repository(id: 'r2', environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              environmentId: 'wsl:Ubuntu',
              responder: (request) => responder(request),
            ),
          ),
        ),
        verificationRootProvider.overrideWithValue(artifacts),
      ],
    );
    container.listen(flutterGateObserverProvider, (_, _) {});
  });

  tearDown(() {
    container.dispose();
    db.close();
    if (artifacts.existsSync()) artifacts.deleteSync(recursive: true);
  });

  FlutterRunTools tools() => FlutterRunTools(container, callerSessionId: 's1');

  Future<Map<String, Object?>> call(Map<String, dynamic> args) async =>
      (await tools().call('flutter_run', args))! as Map<String, Object?>;

  FakeTerminalInstance paneOf(String paneId) =>
      container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId)!
          as FakeTerminalInstance;

  Future<void> settle() =>
      container.read(flutterGateObserverProvider.notifier).drain();

  group('what it refuses before it does anything', () {
    test('no action names all six', () async {
      expect(
        () => tools().call('flutter_run', <String, dynamic>{}),
        throwsA(
          isA<ArgumentError>().having(
            (error) => '${error.message}',
            'message',
            allOf(contains('run, stop, status'), contains('analyze')),
          ),
        ),
      );
    });

    test(
      'an unknown action says so rather than doing the nearest thing',
      () async {
        expect(
          () => tools().call('flutter_run', {'action': 'launch'}),
          throwsA(
            isA<ArgumentError>().having(
              (error) => '${error.message}',
              'message',
              contains('Unknown action "launch"'),
            ),
          ),
        );
      },
    );

    test('no checkoutId points at list_checkouts and says why an id', () async {
      expect(
        () => tools().call('flutter_run', {'action': 'pubGet'}),
        throwsA(
          isA<ArgumentError>().having(
            (error) => '${error.message}',
            'message',
            allOf(
              contains('list_checkouts'),
              contains('which environment the commands run in'),
            ),
          ),
        ),
      );
    });

    test('run with no deviceId names where the ids come from', () async {
      expect(
        () =>
            tools().call('flutter_run', {'action': 'run', 'checkoutId': 'r2'}),
        throwsA(
          isA<ArgumentError>().having(
            (error) => '${error.message}',
            'message',
            allOf(contains('flutter devices'), contains('list_devices')),
          ),
        ),
      );
    });

    test('an absolute projectDirectory is refused, not joined', () async {
      expect(
        () => tools().call('flutter_run', {
          'action': 'pubGet',
          'checkoutId': 'r2',
          'projectDirectory': '/etc',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('the preflight is in the answer', () {
    test('the §17 refusal comes back whole, and nothing was started', () async {
      responder = (request) => request.arguments.contains('command -v flutter')
          ? const CommandResult(
              exitCode: 0,
              stdout: '/mnt/c/Users/dlohani/flutter/bin/flutter\n',
              stderr: '',
            )
          : const CommandResult(exitCode: 0, stdout: '', stderr: '');
      final answer = await call({'action': 'pubGet', 'checkoutId': 'r2'});
      final preflight = answer['preflight']! as Map<String, Object?>;
      expect(preflight['ok'], isFalse);
      expect(preflight['problem'], 'noSdk');
      expect('${preflight['reason']}', contains('§17'));
      expect(answer.containsKey('run'), isFalse);
    });

    test('a clear preflight is still reported', () async {
      final answer = await call({'action': 'pubGet', 'checkoutId': 'r2'});
      expect(answer['preflight'], {'ok': true});
    });
  });

  group('run', () {
    Future<Map<String, Object?>> launch() => call({
      'action': 'run',
      'checkoutId': 'r2',
      'deviceId': 'emulator-5554',
    });

    test('the answer names the pane and says nothing waits for it', () async {
      final answer = await launch();
      final run = answer['run']! as Map<String, Object?>;
      expect(run['kind'], 'run');
      expect(run['deviceId'], 'emulator-5554');
      expect(run['liveness'], 'running');
      expect(run['projectDirectory'], '/home/me/app');
      expect(
        '${answer['summary']}',
        contains('where the developer can see it'),
      );
      expect('${answer['summary']}', contains('${run['paneId']}'));
    });

    test(
      'a launch answer carries no log: nothing has gone wrong yet',
      () async {
        expect((await launch())['run'], isNot(contains('log')));
      },
    );

    test('a second launch onto the same device is refused by name', () async {
      final first = await launch();
      final second = await launch();
      final preflight = second['preflight']! as Map<String, Object?>;
      expect(preflight['problem'], 'alreadyRunning');
      expect(
        '${preflight['reason']}',
        contains('${(first['run']! as Map<String, Object?>)['paneId']}'),
      );
      expect(second.containsKey('run'), isFalse);
    });
  });

  group('status', () {
    test('nothing started says so, and does not claim anything about runs '
        'somebody else began', () async {
      final answer = await call({'action': 'status'});
      expect(answer['runs'], isEmpty);
      expect('${answer['summary']}', contains('flutter_apps is where those'));
    });

    test('a run still going carries its log', () async {
      final launched = await call({
        'action': 'run',
        'checkoutId': 'r2',
        'deviceId': 'emulator-5554',
      });
      final paneId = '${(launched['run']! as Map<String, Object?>)['paneId']}';
      paneOf(paneId).terminal.write('Running Gradle task assembleDebug...\r\n');

      final answer = await call({'action': 'status', 'paneId': paneId});
      final run = answer['run']! as Map<String, Object?>;
      expect(run['liveness'], 'running');
      expect((run['log']! as List<Object?>).join('\n'), contains('Gradle'));
    });

    test(
      'a gate that passed comes back as a verdict, not a transcript',
      () async {
        final started = await call({'action': 'analyze', 'checkoutId': 'r2'});
        final paneId = '${(started['run']! as Map<String, Object?>)['paneId']}';
        paneOf(paneId).terminal.write('No issues found!\r\n');
        paneOf(paneId).exitWith(0);
        await settle();

        final answer = await call({'action': 'status', 'paneId': paneId});
        final run = answer['run']! as Map<String, Object?>;
        expect(run['exitCode'], 0);
        expect(run['liveness'], 'finished');
        expect(run.containsKey('log'), isFalse);
        expect('${run['logNote']}', contains('finished cleanly'));
        expect(run['verificationRunId'], isNotNull);
      },
    );

    test(
      'a failed build carries the tail, because that is the question',
      () async {
        final started = await call({'action': 'test', 'checkoutId': 'r2'});
        final paneId = '${(started['run']! as Map<String, Object?>)['paneId']}';
        paneOf(paneId).terminal.write(
          'lib/main.dart:12:3: Error: Expected a declaration.\r\n'
          'Target kernel_snapshot_program failed.\r\n',
        );
        paneOf(paneId).exitWith(1);
        await settle();

        final answer = await call({'action': 'status', 'paneId': paneId});
        final run = answer['run']! as Map<String, Object?>;
        expect(run['exitCode'], 1);
        final log = (run['log']! as List<Object?>).join('\n');
        expect(log, contains('Error:'));
        expect(log, contains('kernel_snapshot_program failed'));
      },
    );

    test('the log is ROWS, and a row is the pane\'s width — which is why the '
        'VM service address is not read from one', () {
      // This pane is forty columns, so the error above comes back split
      // mid-word: "…Expected a de" / "claration." Nothing is wrong with that
      // for a human reading a failure, and it is exactly why
      // `vmServiceUriInPaneRows` matches an announcement across rows and why
      // `--vmservice-out-file` is the address's real source.
      expect(kFlutterRunLogRows, greaterThan(0));
    });

    test('a pane the app no longer has reads unknown and says why', () async {
      final started = await call({'action': 'analyze', 'checkoutId': 'r2'});
      final paneId = '${(started['run']! as Map<String, Object?>)['paneId']}';
      container
          .read(terminalSessionsControllerProvider.notifier)
          .closePane(paneId, detach: false);

      final run =
          (await call({'action': 'status', 'paneId': paneId}))['run']!
              as Map<String, Object?>;
      expect(run['liveness'], 'unknown');
      expect('${run['livenessNote']}', contains('unknown rather than no'));
    });

    test('an unknown paneId is answered, not thrown at', () async {
      final answer = await call({'action': 'status', 'paneId': 'nope'});
      expect(answer['runs'], isEmpty);
      expect('${answer['summary']}', contains('No run in pane nope'));
    });

    test('the whole list, with no logs in it', () async {
      await call({'action': 'pubGet', 'checkoutId': 'r2'});
      await call({'action': 'analyze', 'checkoutId': 'r2'});
      final runs = (await call({'action': 'status'}))['runs']! as List<Object?>;
      expect(runs, hasLength(2));
      for (final run in runs.cast<Map<String, Object?>>()) {
        expect(run.containsKey('log'), isFalse);
      }
    });
  });

  group('stop', () {
    test('with one thing running it needs no paneId', () async {
      await call({
        'action': 'run',
        'checkoutId': 'r2',
        'deviceId': 'emulator-5554',
      });
      final answer = await call({'action': 'stop'});
      expect(answer['stopped'], isTrue);
      expect(answer['summary'], contains('stopped rather than detached'));
      // A pane we ended on purpose is not a blind spot, and does not read
      // like one.
      final run = answer['run']! as Map<String, Object?>;
      expect('${run['livenessNote']}', contains('not a blind spot'));
      expect('${run['livenessNote']}', isNot(contains('unknown rather than')));
    });

    test('with two running it refuses to guess which', () async {
      await call({'action': 'pubGet', 'checkoutId': 'r2'});
      await call({'action': 'analyze', 'checkoutId': 'r2'});
      final answer = await call({'action': 'stop'});
      expect(answer['stopped'], isFalse);
    });

    test('with nothing running it says so rather than failing', () async {
      final answer = await call({'action': 'stop'});
      expect(answer['stopped'], isFalse);
      expect('${answer['summary']}', contains('nothing to stop'));
    });

    test('an unknown paneId says where the real ones are', () async {
      final answer = await call({'action': 'stop', 'paneId': 'ghost'});
      expect(answer['stopped'], isFalse);
      expect('${answer['summary']}', contains('"status" lists'));
    });
  });

  test('extra arguments reach the command', () async {
    final started = await call({
      'action': 'test',
      'checkoutId': 'r2',
      'arguments': ['--exclude-tags=live-ssh,live-wsl'],
    });
    final paneId = '${(started['run']! as Map<String, Object?>)['paneId']}';
    expect(paneOf(paneId).agentLaunch!.arguments, [
      'test',
      '--exclude-tags=live-ssh,live-wsl',
    ]);
  });

  test(
    'a sub-project is joined onto the checkout in its own spelling',
    () async {
      final started = await call({
        'action': 'pubGet',
        'checkoutId': 'r2',
        'projectDirectory': 'packages/mobile',
      });
      final run = started['run']! as Map<String, Object?>;
      expect(run['projectDirectory'], '/home/me/app/packages/mobile');
    },
  );
}
