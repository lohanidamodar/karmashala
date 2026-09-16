import 'dart:async';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';

const _spec = AgentLaunchSpec(
  baseArguments: ['--headless'],
  permission: testPermissionSupport,
  resume: AgentResume.flag('--continue'),
);

/// [selection] resolved against [spec], the way the caller that holds the
/// descriptor resolves it before an adapter ever sees it.
ResolvedPermission _resolved(AgentLaunchSpec spec, PermissionSelection? selection) =>
    ResolvedPermission.of(spec.permission, selection);

AgentLaunch _launch(ResolvedPermission permission, String? resume) => AgentLaunch(
  workingDirectory: repository().path,
  installation: agentInstallation(
    agentId: 'roverCli',
    path: r'C:\bin\rover.exe',
  ),
  permission: permission,
  resumeSessionId: resume,
);

void main() {
  group('genericLaunchArgs', () {
    test('are exactly what the descriptor declares', () {
      expect(
        genericLaunchArgs(
          _spec,
          _launch(_resolved(_spec, bypassSelection), 'sid'),
        ),
        ['--headless', '--bypass', '--continue', 'sid'],
      );
      expect(
        genericLaunchArgs(_spec, _launch(_resolved(_spec, askSelection), null)),
        ['--headless', '--mode', 'ask'],
      );
    });

    test('"enforce nothing" adds nothing, and is not the default', () {
      // The state the carry rule produces when every mode an agent has is more
      // permissive than what was asked for. It has to stay distinguishable
      // from a *null* selection, which means "nobody chose" and does pass the
      // declared default's flags.
      expect(
        genericLaunchArgs(
          _spec,
          _launch(_resolved(_spec, PermissionSelection.empty), null),
        ),
        ['--headless'],
      );
      expect(
        genericLaunchArgs(_spec, _launch(_resolved(_spec, null), null)),
        ['--headless', '--mode', 'ask'],
      );
    });

    test('an agent with no launch spec runs bare', () {
      // Including its permission: a descriptor that declares no modes resolves
      // every selection to nothing, so asking for a bypass still contributes no
      // flags rather than handing an unknown CLI a flag invented for another.
      const bare = AgentLaunchSpec();
      expect(
        genericLaunchArgs(
          bare,
          _launch(_resolved(bare, bypassSelection), 'sid'),
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
      runnerFor: (_) => runner,
    );

    expect(adapter.agentId, 'roverCli');
    adapter.start(_launch(_resolved(_spec, bypassSelection), null));
    await Future<void>.delayed(Duration.zero);

    final req = runner.startRequests.single;
    expect(req.executable, r'C:\bin\rover.exe');
    expect(req.arguments, ['--headless', '--bypass']);
  });
}
