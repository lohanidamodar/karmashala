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
    final runs = [for (final m in messages) ?m.background];
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

  test('the chat note says "finished" only for the final notice; the '
      'interim one reported progress', () async {
    writeParent([
      agentCall('toolu_1', 'Sleep 60 then report'),
      agentLaunched('toolu_1', 'a1', 'Sleep 60 then report'),
      notified(
        'a1',
        '2026-10-04T14:49:22.676Z',
        status: 'completed',
        summary: 'Agent "Sleep 60 then report" finished',
        interim: true,
      ),
      notified(
        'a1',
        '2026-10-04T14:51:22.053Z',
        status: 'completed',
        summary: 'Agent "Sleep 60 then report" finished',
      ),
    ]);
    final notes = [
      for (final m in await read())
        if (m.role == 'user') ?taskNotificationLine(m.text),
    ];
    expect(notes, [
      'Agent "Sleep 60 then report" reported progress',
      'Agent "Sleep 60 then report" finished',
    ]);
  });

  test('a background command is listed too, and how it ended', () async {
    writeParent([
      bashCall('toolu_3', 'Run the app tests'),
      bashLaunched('toolu_3', 'brr24bsfs'),
      notified(
        'brr24bsfs',
        '2026-10-04T14:55:00.000Z',
        status: 'failed',
        summary:
            'Background command "Run the app tests" failed with exit '
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

  group('a run that ended though nothing reported it finishing', () {
    // Shapes recorded from Claude Code 2.1.284–2.1.287 on 2026-10-05.
    Map<String, Object?> taskStopCall(String id, String taskId) => {
      'type': 'assistant',
      'timestamp': '2026-10-04T15:10:00.000Z',
      'message': {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': id,
            'name': 'TaskStop',
            'input': {'task_id': taskId},
          },
        ],
      },
    };

    Map<String, Object?> taskStopped(String id, String taskId) => {
      'type': 'user',
      'timestamp': '2026-10-04T15:10:00.300Z',
      'message': {
        'role': 'user',
        'content': [
          {
            'tool_use_id': id,
            'type': 'tool_result',
            'content':
                '{"message":"Successfully stopped task: $taskId (flutter '
                'test)","task_id":"$taskId","task_type":"local_bash",'
                '"command":"flutter test"}',
          },
        ],
      },
      'toolUseResult': {
        'message': 'Successfully stopped task: $taskId (flutter test)',
        'task_id': taskId,
        'task_type': 'local_bash',
        'command': 'flutter test',
      },
    };

    Map<String, Object?> written(Map<String, Object?> line, String version) => {
      ...line,
      'version': version,
    };

    test('a notice that it was stopped ends it', () async {
      writeParent([
        bashCall('toolu_3', 'Start the debug probe'),
        bashLaunched('toolu_3', 'b1'),
        notified(
          'b1',
          '2026-10-04T15:00:00.000Z',
          status: 'stopped',
          summary: 'Background command "Start the debug probe" was stopped',
        ),
      ]);

      final run = runOf(await read(), 'b1');
      expect(run.state, BackgroundRunState.killed);
      expect(run.endedAt, DateTime.utc(2026, 10, 4, 15));
    });

    test('the agent stopping it with TaskStop ends it, when the stop '
        'answered', () async {
      writeParent([
        bashCall('toolu_3', 'Start the debug probe'),
        bashLaunched('toolu_3', 'b1'),
        bashCall('toolu_4', 'Watch the round-4 fix session'),
        bashLaunched('toolu_4', 'b2'),
        taskStopCall('toolu_5', 'b1'),
        taskStopped('toolu_5', 'b1'),
      ]);

      final messages = await read();
      final stopped = runOf(messages, 'b1');
      expect(stopped.state, BackgroundRunState.killed);
      expect(stopped.endedAt, DateTime.utc(2026, 10, 4, 15, 10, 0, 300));
      expect(runOf(messages, 'b2').state, BackgroundRunState.running);
    });

    test('a refused TaskStop leaves it running', () async {
      final refused = {
        'type': 'user',
        'timestamp': '2026-10-04T15:10:00.300Z',
        'message': {
          'role': 'user',
          'content': [
            {
              'tool_use_id': 'toolu_5',
              'type': 'tool_result',
              'content': 'No task found with ID: b1',
              'is_error': true,
            },
          ],
        },
      };
      writeParent([
        bashCall('toolu_3', 'Start the debug probe'),
        bashLaunched('toolu_3', 'b1'),
        taskStopCall('toolu_5', 'b1'),
        refused,
      ]);

      expect(runOf(await read(), 'b1').state, BackgroundRunState.running);
    });

    test('the notice that tasks did not finish before the previous session '
        'ended stops every task it names', () async {
      writeParent([
        bashCall('toolu_3', 'Start the debug probe'),
        bashLaunched('toolu_3', 'b1'),
        bashCall('toolu_4', 'Build and run the app'),
        bashLaunched('toolu_4', 'b2'),
        {
          'type': 'user',
          'timestamp': '2026-10-05T09:04:54.559Z',
          'message': {
            'role': 'user',
            'content':
                '<task-notification>\n<task-id>b1</task-id>\n'
                '<task-id>b2</task-id>\n'
                '<task-id>__orphan_summary__:shell</task-id>\n'
                '<status>stopped</status>\n<summary>2 background shell '
                'command tasks didn\'t finish before the previous session '
                'ended. Task ids: b1, b2.</summary>\n<note>No completion '
                'record was found for them in the previous session. They '
                'have been marked stopped.</note>\n</task-notification>',
          },
        },
      ]);

      final messages = await read();
      for (final id in ['b1', 'b2']) {
        final run = runOf(messages, id);
        expect(run.state, BackgroundRunState.killed, reason: id);
        expect(run.endedAt, DateTime.utc(2026, 10, 5, 9, 4, 54, 559));
      }
    });

    test('one the agent\'s earlier process left running, with nothing said '
        'of it since that process was replaced, is not recorded, never '
        'running', () async {
      writeParent([
        written(bashCall('toolu_3', 'Start the debug probe'), '2.1.284'),
        written(bashLaunched('toolu_3', 'b1'), '2.1.284'),
        written({
          'type': 'user',
          'timestamp': '2026-10-05T09:05:16.748Z',
          'message': {'role': 'user', 'content': 'carry on'},
        }, '2.1.287'),
        written(bashCall('toolu_4', 'Build and run the app'), '2.1.287'),
        written(bashLaunched('toolu_4', 'b2'), '2.1.287'),
      ]);

      final messages = await read();
      final lost = runOf(messages, 'b1');
      expect(lost.state, BackgroundRunState.ended);
      expect(lost.endedAt, isNull);
      expect(runOf(messages, 'b2').state, BackgroundRunState.running);
    });
  });
}
