import 'dart:async';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  group('parseAntigravityMessage', () {
    test('maps structured JSON message/status/error', () {
      expect(
        parseAntigravityMessage(
          '{"type":"message","text":"hi"}',
        ).single.data['text'],
        'hi',
      );
      expect(
        parseAntigravityMessage('{"type":"status","state":"busy"}').single.type,
        SessionEventTypes.agentStatus,
      );
      expect(
        parseAntigravityMessage('{"type":"error","message":"x"}').single.type,
        SessionEventTypes.error,
      );
    });

    test('treats a non-JSON line as plain agent text (compatibility)', () {
      final events = parseAntigravityMessage('just some output');
      expect(events.single.type, SessionEventTypes.agentMessage);
      expect(events.single.data['text'], 'just some output');
    });

    test('ignores blank lines and unknown JSON types', () {
      expect(parseAntigravityMessage('   '), isEmpty);
      expect(parseAntigravityMessage('{"type":"nope"}'), isEmpty);
    });
  });

  test('encodeAntigravityUserMessage sends plain text', () {
    expect(encodeAntigravityUserMessage('go ahead'), 'go ahead');
  });

  test('AntigravityAgentSession streams events and sends plain text', () async {
    final handle = FakeProcessHandle();
    final session = AntigravityAgentSession(Future.value(handle));
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

  test('AntigravityAdapter starts the executable bare', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final runner = FakeCommandRunner();
    final adapter = AntigravityAdapter(
      runnerFor: (_) => runner,
    );

    adapter.start(
      AgentLaunch(
        workingDirectory: repository().path,
        installation: agentInstallation(
          agentId: AgentIds.antigravity,
          path: r'C:\bin\antigravity.exe',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final req = runner.startRequests.single;
    expect(req.executable, r'C:\bin\antigravity.exe');
    // `--stdio` is not a flag this CLI has. A default launch passes
    // nothing: `agy` already prompts before tool use, and the headless
    // stream-json protocol it documents has not been run.
    expect(req.arguments, isEmpty);
  });
}
