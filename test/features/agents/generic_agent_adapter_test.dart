import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/generic_agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

const _spec = AgentLaunchSpec(
  baseArguments: ['--headless'],
  permissionModes: {
    PermissionMode.ask: PermissionModeMapping.exact([]),
    PermissionMode.bypass: PermissionModeMapping.exact(['--trust']),
  },
  resume: AgentResume.flag('--continue'),
);

AgentLaunch _launch(PermissionMode mode, String? resume) => AgentLaunch(
  workingDirectory: repository().path,
  installation: agentInstallation(
    agentId: 'roverCli',
    path: r'C:\bin\rover.exe',
  ),
  permissionMode: mode,
  resumeSessionId: resume,
);

void main() {
  group('genericLaunchArgs', () {
    test('are exactly what the descriptor declares', () {
      expect(genericLaunchArgs(_spec, _launch(PermissionMode.bypass, 'sid')), [
        '--headless',
        '--trust',
        '--continue',
        'sid',
      ]);
      expect(genericLaunchArgs(_spec, _launch(PermissionMode.ask, null)), [
        '--headless',
      ]);
    });

    test('an agent with no launch spec runs bare', () {
      expect(
        genericLaunchArgs(
          const AgentLaunchSpec(),
          _launch(PermissionMode.bypass, 'sid'),
        ),
        isEmpty,
      );
    });
  });

  test('every non-empty stdout line becomes one agent message', () {
    expect(parseGenericAgentLine('  '), isEmpty);
    final events = parseGenericAgentLine('{"type":"message"}');
    expect(events.single.type, SessionEventTypes.agentMessage);
    expect(events.single.data['role'], 'assistant');
    // No protocol knowledge: even a JSON-looking line is passed through as text.
    expect(events.single.data['text'], '{"type":"message"}');
  });

  test('the session streams stdout and writes messages verbatim', () async {
    final handle = FakeProcessHandle();
    final session = GenericAgentSession(Future.value(handle));
    final events = <AgentEvent>[];
    final done = Completer<void>();
    session.events.listen(events.add, onDone: done.complete);

    await Future<void>.delayed(Duration.zero);
    await session.send('hello');
    handle.emitStdout('plain reply');
    handle.complete(0);
    await done.future;

    expect(handle.written.single, 'hello');
    expect(events.single.data['text'], 'plain reply');
  });

  test('the adapter launches the recorded executable', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final runner = FakeCommandRunner();
    final adapter = GenericAgentAdapter(
      agentId: 'roverCli',
      launch: _spec,
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
    );

    expect(adapter.agentId, 'roverCli');
    adapter.start(_launch(PermissionMode.bypass, null));
    await Future<void>.delayed(Duration.zero);

    final req = runner.startRequests.single;
    expect(req.executable, r'C:\bin\rover.exe');
    expect(req.arguments, ['--headless', '--trust']);
  });
}
