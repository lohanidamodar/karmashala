import 'dart:async';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/claude_code_adapter.dart';
import 'package:chitragupta/src/features/agents/domain/agent_adapter.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_event_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  group('parseClaudeMessage', () {
    test('system init becomes an agent status', () {
      final events = parseClaudeMessage(
        '{"type":"system","subtype":"init","session_id":"cli-1"}',
      );
      expect(events.single.type, SessionEventTypes.agentStatus);
      expect(events.single.data['state'], 'init');
      expect(events.single.data['sessionId'], 'cli-1');
    });

    test('an assistant message yields text and tool_use events in order', () {
      final events = parseClaudeMessage(
        '{"type":"assistant","message":{"content":['
        '{"type":"text","text":"hi"},'
        '{"type":"tool_use","name":"read","input":{"path":"a"}}'
        ']}}',
      );
      expect(events.map((e) => e.type), [
        SessionEventTypes.agentMessage,
        'tool.call',
      ]);
      expect(events[0].data['text'], 'hi');
      expect(events[1].data['name'], 'read');
    });

    test('result and error map appropriately', () {
      expect(
        parseClaudeMessage(
          '{"type":"result","subtype":"success"}',
        ).single.data['state'],
        'success',
      );
      expect(
        parseClaudeMessage('{"type":"error","message":"boom"}').single.type,
        SessionEventTypes.error,
      );
    });

    test('blank, malformed, and unknown lines yield no events', () {
      expect(parseClaudeMessage(''), isEmpty);
      expect(parseClaudeMessage('nope'), isEmpty);
      expect(parseClaudeMessage('{"type":"user"}'), isEmpty);
    });
  });

  test('encodeClaudeUserMessage wraps the message in a stream-json envelope', () {
    expect(
      encodeClaudeUserMessage('hi'),
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}',
    );
  });

  group('ClaudeCodeAgentSession', () {
    test('streams normalized events from stdout', () async {
      final handle = FakeProcessHandle();
      final session = ClaudeCodeAgentSession(Future.value(handle));
      final events = <AgentEvent>[];
      final done = Completer<void>();
      session.events.listen(events.add, onDone: done.complete);

      await Future<void>.delayed(Duration.zero);
      handle.emitStdout(
        '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}',
      );
      handle.complete(0);
      await done.future;

      expect(events.single.data['text'], 'hello');
    });

    test('send writes an encoded stream-json line', () async {
      final handle = FakeProcessHandle();
      final session = ClaudeCodeAgentSession(Future.value(handle));
      await Future<void>.delayed(Duration.zero);
      await session.send('go');
      expect(handle.written.single, contains('"text":"go"'));
    });
  });

  group('ClaudeCodeAdapter', () {
    test('starts claude with stream-json in/out', () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final runner = FakeCommandRunner();
      final adapter = ClaudeCodeAdapter(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        environmentDao: ExecutionEnvironmentDao(db),
      );

      adapter.start(
        AgentLaunch(
          workingDirectory: repository().path,
          installation: agentInstallation(path: r'C:\bin\claude.exe'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final req = runner.startRequests.single;
      expect(req.executable, r'C:\bin\claude.exe');
      expect(req.arguments, [
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--verbose',
      ]);
    });
  });
}
