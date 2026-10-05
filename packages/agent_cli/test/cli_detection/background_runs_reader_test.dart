import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// **Every background run a session started, with what became of it**: agents
/// launched with `run_in_background` and background shell commands, read from
/// the parent's own transcript. The shapes are Claude Code 2.1.287's, recorded
/// on 2026-10-04: a launch result whose content is a list of text blocks, a
/// first notice that says it may be interim, and the final one after it.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bg_runs'));
  tearDown(() => removeTempDirectory(root));

  String parentPath() => '${root.path}/s1.jsonl';
  void writeParent(List<Object> lines) => File(parentPath()).writeAsStringSync(
    lines.map((l) => l is String ? l : jsonEncode(l)).join('\n'),
  );

  Future<List<TranscriptMessage>> read() =>
      readCliTranscript(parentPath(), AgentIds.claudeCode);

  Map<String, Object?> agentCall(String id, String description) => {
    'type': 'assistant',
    'timestamp': '2026-10-04T14:49:15.000Z',
    'message': {
      'role': 'assistant',
      'content': [
        {
          'type': 'tool_use',
          'id': id,
          'name': 'Agent',
          'input': {
            'description': description,
            'subagent_type': 'general-purpose',
            'prompt': 'Do it.',
            'run_in_background': true,
          },
        },
      ],
    },
  };

  Map<String, Object?> agentLaunched(
    String id,
    String agentId,
    String description,
  ) => {
    'type': 'user',
    'timestamp': '2026-10-04T14:49:15.138Z',
    'message': {
      'role': 'user',
      'content': [
        {
          'tool_use_id': id,
          'type': 'tool_result',
          'content': [
            {
              'type': 'text',
              'text':
                  'Async agent launched successfully.\nagentId: $agentId\n'
                  'The agent is working in the background.',
            },
          ],
        },
      ],
    },
    'toolUseResult': {
      'isAsync': true,
      'status': 'async_launched',
      'agentId': agentId,
      'description': description,
    },
  };

  Map<String, Object?> bashCall(String id, String description) => {
    'type': 'assistant',
    'timestamp': '2026-10-04T14:50:00.000Z',
    'message': {
      'role': 'assistant',
      'content': [
        {
          'type': 'tool_use',
          'id': id,
          'name': 'Bash',
          'input': {
            'command': 'flutter test',
            'description': description,
            'run_in_background': true,
          },
        },
      ],
    },
  };

  Map<String, Object?> bashLaunched(String id, String taskId) => {
    'type': 'user',
    'timestamp': '2026-10-04T14:50:00.200Z',
    'message': {
      'role': 'user',
      'content': [
        {
          'tool_use_id': id,
          'type': 'tool_result',
          'content':
              'Command running in background with ID: $taskId. Output is '
              'being written to: C:\\tmp\\$taskId.output.',
          'is_error': false,
        },
      ],
    },
    'toolUseResult': {
      'stdout': '',
      'stderr': '',
      'interrupted': false,
      'backgroundTaskId': taskId,
    },
  };

  Map<String, Object?> notified(
    String taskId,
    String at, {
    required String status,
    required String summary,
    bool interim = false,
  }) => {
    'type': 'user',
    'timestamp': at,
    'message': {
      'role': 'user',
      'content':
          '<task-notification>\n<task-id>$taskId</task-id>\n'
          '<status>$status</status>\n<summary>$summary</summary>\n'
          '${interim ? '<note>This agent stopped with background work of '
                    'its own still running. It may resume on its own when '
                    'that work completes or reports, and the same task-id '
                    'notifies again if it does; the result below may be '
                    'interim.</note>\n' : ''}'
          '</task-notification>',
    },
    'origin': {'kind': 'task-notification'},
  };

  BackgroundRun runOf(List<TranscriptMessage> messages, String id) =>
      messages.firstWhere((m) => m.background?.id == id).background!;

  test('two agents launched in the background are both listed, running, with '
      'their descriptions', () async {
    writeParent([
      agentCall('toolu_1', 'Strip idle detection'),
      agentLaunched('toolu_1', 'a1', 'Strip idle detection'),
      agentCall('toolu_2', 'Unify tasks and work items'),
      agentLaunched('toolu_2', 'a2', 'Unify tasks and work items'),
    ]);

    final messages = await read();
    final runs = [
      for (final m in messages)
        if (m.background case final run?) run,
    ];
    expect(runs.map((r) => r.id), ['a1', 'a2']);
    expect(runs.map((r) => r.description), [
      'Strip idle detection',
      'Unify tasks and work items',
    ]);
    for (final run in runs) {
      expect(run.kind, BackgroundRunKind.agent);
      expect(run.state, BackgroundRunState.running);
      expect(run.endedAt, isNull);
    }
    // Launched 14:49:15.000 — the call, not the stub after it.
    expect(
      messages.firstWhere((m) => m.background?.id == 'a1').at,
      DateTime.utc(2026, 10, 4, 14, 49, 15),
    );
  });

  test('a notice that says it may be interim leaves the agent running; the '
      'one after it finishes it', () async {
    writeParent([
      agentCall('toolu_1', 'Sleep then reply done'),
      agentLaunched('toolu_1', 'a1', 'Sleep then reply done'),
      notified(
        'a1',
        '2026-10-04T14:49:22.676Z',
        status: 'completed',
        summary: 'Agent "Sleep then reply done" finished',
        interim: true,
      ),
    ]);
    var messages = await read();
    expect(runOf(messages, 'a1').state, BackgroundRunState.running);
    expect(
      messages.firstWhere((m) => m.background != null).pendingBackgroundAgentId,
      'a1',
    );

    writeParent([
      agentCall('toolu_1', 'Sleep then reply done'),
      agentLaunched('toolu_1', 'a1', 'Sleep then reply done'),
      notified(
        'a1',
        '2026-10-04T14:49:22.676Z',
        status: 'completed',
        summary: 'Agent "Sleep then reply done" finished',
        interim: true,
      ),
      notified(
        'a1',
        '2026-10-04T14:51:22.053Z',
        status: 'completed',
        summary: 'Agent "Sleep then reply done" finished',
      ),
    ]);
    messages = await read();
    final run = runOf(messages, 'a1');
    expect(run.state, BackgroundRunState.completed);
    expect(run.endedAt, DateTime.utc(2026, 10, 4, 14, 51, 22, 53));
    expect(run.summary, 'Agent "Sleep then reply done" finished');
    expect(
      messages.firstWhere((m) => m.background != null).pendingBackgroundAgentId,
      isNull,
    );
  });

  test('a background command is listed too, and how it ended', () async {
    writeParent([
      bashCall('toolu_3', 'Run the app tests'),
      bashLaunched('toolu_3', 'brr24bsfs'),
      notified(
        'brr24bsfs',
        '2026-10-04T14:55:00.000Z',
        status: 'failed',
        summary: 'Background command "Run the app tests" failed with exit '
            'code 1',
      ),
    ]);

    final run = runOf(await read(), 'brr24bsfs');
    expect(run.kind, BackgroundRunKind.command);
    expect(run.description, 'Run the app tests');
    expect(run.state, BackgroundRunState.failed);
    expect(run.endedAt, DateTime.utc(2026, 10, 4, 14, 55));
  });

  test('a killed agent says so', () async {
    writeParent([
      agentCall('toolu_1', 'Ping then reply done'),
      agentLaunched('toolu_1', 'a1', 'Ping then reply done'),
      notified(
        'a1',
        '2026-10-04T15:00:00.000Z',
        status: 'killed',
        summary: 'Agent "Ping then reply done" was stopped by user',
      ),
    ]);

    expect(runOf(await read(), 'a1').state, BackgroundRunState.killed);
  });

  test('a run crosses the wire whole', () async {
    writeParent([
      agentCall('toolu_1', 'Strip idle detection'),
      agentLaunched('toolu_1', 'a1', 'Strip idle detection'),
    ]);
    final row = (await read()).firstWhere((m) => m.background != null);
    final back = TranscriptMessage.fromJson(
      jsonDecode(jsonEncode(row.toJson())) as Map<String, Object?>,
    );
    expect(back.background, row.background);
  });
}
