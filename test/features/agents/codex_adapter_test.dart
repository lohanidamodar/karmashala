import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/codex_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

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

  group('CodexAdapter', () {
    test('starts "codex app-server" in the installation environment', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final runner = FakeCommandRunner();
      final adapter = CodexAdapter(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        environmentDao: ExecutionEnvironmentDao(db),
      );

      adapter.start(
        AgentLaunch(
          workingDirectory: repository().path,
          installation: agentInstallation(
            agentId: AgentIds.codex,
            path: r'C:\bin\codex.exe',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final req = runner.startRequests.single;
      expect(req.executable, r'C:\bin\codex.exe');
      // Default permission (ask) maps to an on-request approval flag.
      expect(req.arguments, ['app-server', '--ask-for-approval', 'on-request']);
      expect(req.workingDirectory!.path, r'C:\src\demo\app');
    });
  });
}
