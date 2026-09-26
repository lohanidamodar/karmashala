import 'dart:async';

import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// What a session that has chosen nothing runs under: this agent's declared
/// default, resolved through the registry the launcher would have used.
final _support = AgentRegistry.builtIn.byId('claudeCode')!.launch.permission;
final _defaultPermission = ResolvedPermission.of(
  _support,
  _support.defaultSelection,
);

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

  group('ClaudeCodeChatProtocol', () {
    test('starts claude with stream-json in/out', () async {
      final runner = FakeCommandRunner();
      final adapter = ClaudeCodeChatProtocol(runnerFor: (_) => runner);

      adapter.start(
        AgentLaunch(
          workingDirectory: repository().path,
          // Resolved by the caller now, not defaulted by the adapter: the
          // adapters hold no flag table of their own any more, so a launch
          // that names no permission passes none.
          permission: _defaultPermission,
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
        // The default `ask` mode, named rather than assumed — see
        // built_in_agents.dart.
        '--permission-mode',
        'manual',
      ]);
    });
  });
}
