import 'dart:io';

import 'package:agent_cli/stream.dart'
    show delegatedChildIdOf, isDelegationToolName;
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart' show SessionMessageDao;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// An ACP parent's launch calls, as the adapters title them, reach the
/// transcript rows the chat reads still recognisable as launches — the folded
/// "Delegated N sessions" card finds them by the same rule
/// (`isDelegationToolName`), and each names the child it started.
void main() {
  late AppDatabase database;
  late Directory temp;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_delegation_calls');
  });
  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  FakeStep launch(String id, String title, String child) => FakeStep.toolCall(
    toolCallId: id,
    title: title,
    kind: ToolKind.other,
    completedContent: [
      ToolCallContentBlock(
        ContentBlock.text(
          '{"state":"started","mode":"async","childSessionId":"$child"}',
        ),
      ),
    ],
  );

  test('claude-agent-acp and codex-acp titles both read as launches, with '
      'their children', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          FakeTurn([
            // claude-agent-acp titles an MCP call with its tool name as is.
            launch('t1', 'mcp__karmashala__subagent_run', 'c1'),
            // codex-acp: `format!("Tool: {}/{}", server, tool)`.
            launch('t2', 'Tool: karmashala/open_new_session', 'c2'),
            const FakeStep.toolCall(toolCallId: 't3', title: 'Read cart.dart'),
            const FakeStep.message('Started two helpers.'),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      sessionId: 'parent',
    );
    await runtime.start();
    await runtime.send('Split it up');
    await runtime.awaitTurn();
    await pump();

    final tools = [
      for (final row in SessionMessageDao(database).listAfter('parent'))
        ?SessionMessageTranscriptSource.project(row).tool,
    ];
    final launches = [
      for (final tool in tools)
        if (isDelegationToolName(tool.name))
          (tool.name, delegatedChildIdOf(tool.output)),
    ];
    expect(launches, [
      ('mcp__karmashala__subagent_run', 'c1'),
      ('Tool: karmashala/open_new_session', 'c2'),
    ]);
    expect(tools.map((t) => t.name), contains('Read cart.dart'));
    await runtime.stop();
  });
}
