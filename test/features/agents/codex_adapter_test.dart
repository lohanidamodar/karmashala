import 'dart:async';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// What a session that has chosen nothing runs under: this agent's declared
/// default, resolved through the registry the launcher would have used.
final _support = AgentRegistry.builtIn.byId('codex')!.launch.permission;
final _defaultPermission = ResolvedPermission.of(
  _support,
  _support.defaultSelection,
);

void main() {
  group('parseCodexMessage', () {
    test('maps agent_message to a normalized agent message', () {
      final e = parseCodexMessage('{"type":"agent_message","text":"hi"}')!;
      expect(e.type, SessionEventTypes.agentMessage);
      expect(e.data['text'], 'hi');
    });

    test('maps status, tool_call, task_complete and error', () {
      expect(
        parseCodexMessage('{"type":"status","state":"thinking"}')!.type,
        SessionEventTypes.agentStatus,
      );
      expect(
        parseCodexMessage('{"type":"tool_call","name":"read"}')!.type,
        'tool.call',
      );
      expect(
        parseCodexMessage('{"type":"task_complete"}')!.data['state'],
        'complete',
      );
      expect(
        parseCodexMessage('{"type":"error","message":"boom"}')!.type,
        SessionEventTypes.error,
      );
    });

    test('captures the resumable id when a thread starts', () {
      final event = parseCodexMessage(
        '{"type":"thread.started","thread":{"id":"thread-1"}}',
      )!;
      expect(event.data['sessionId'], 'thread-1');
    });

    test('ignores blank, malformed, and unknown lines', () {
      expect(parseCodexMessage(''), isNull);
      expect(parseCodexMessage('not json'), isNull);
      expect(parseCodexMessage('{"type":"mystery"}'), isNull);
    });
  });

  test('encodeCodexUserMessage produces a user_message line', () {
    expect(
      encodeCodexUserMessage('hello'),
      '{"type":"user_message","text":"hello"}',
    );
  });

  group('CodexAgentSession', () {
    test('emits normalized events from stdout and closes on exit', () async {
      final handle = FakeProcessHandle();
      final session = CodexAgentSession(Future.value(handle));
      final events = <AgentEvent>[];
      final done = Completer<void>();
      session.events.listen(events.add, onDone: done.complete);

      await Future<void>.delayed(Duration.zero); // let _attach run
      handle.emitStdout('{"type":"agent_message","text":"hello"}');
      handle.emitStdout('{"type":"status","state":"thinking"}');
      handle.complete(0);
      await done.future;

      expect(events.map((e) => e.type), [
        SessionEventTypes.agentMessage,
        SessionEventTypes.agentStatus,
      ]);
    });

    test('send writes an encoded protocol line to stdin', () async {
      final handle = FakeProcessHandle();
      final session = CodexAgentSession(Future.value(handle));
      await Future<void>.delayed(Duration.zero);

      await session.send('do it');
      expect(handle.written, ['{"type":"user_message","text":"do it"}']);
    });

    test('messages sent before the process is ready are flushed', () async {
      final completer = Completer<FakeProcessHandle>();
      final session = CodexAgentSession(completer.future);
      await session.send('queued');

      final handle = FakeProcessHandle();
      completer.complete(handle);
      await Future<void>.delayed(Duration.zero);

      expect(handle.written, ['{"type":"user_message","text":"queued"}']);
    });

    test('stop kills the process', () async {
      final handle = FakeProcessHandle();
      final session = CodexAgentSession(Future.value(handle));
      await Future<void>.delayed(Duration.zero);
      await session.stop();
      expect(handle.killed, isTrue);
    });
  });

  group('CodexChatProtocol', () {
    test('starts "codex app-server" in the installation environment', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final runner = FakeCommandRunner();
      final adapter = CodexChatProtocol(runnerFor: (_) => runner);

      adapter.start(
        AgentLaunch(
          workingDirectory: repository().path,
          // Resolved by the caller now, not defaulted by the adapter: the
          // adapters hold no flag table of their own any more, so a launch
          // that names no permission passes none.
          permission: _defaultPermission,
          installation: agentInstallation(
            agentId: AgentIds.codex,
            path: r'C:\bin\codex.exe',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final req = runner.startRequests.single;
      expect(req.executable, r'C:\bin\codex.exe');
      // Codex's declared default is **both** axes, which is the one command
      // line v35 changes: it used to send `--ask-for-approval on-request` and
      // no `--sandbox` at all, leaving whatever `~/.codex/config.toml` said in
      // charge. The approval policy is unchanged; the sandbox is now explicit
      // and matches Codex's own default.
      expect(req.arguments, [
        'app-server',
        '--sandbox',
        'workspace-write',
        '--ask-for-approval',
        'on-request',
      ]);
      expect(req.workingDirectory!.path, r'C:\src\demo\app');
    });
  });
}
