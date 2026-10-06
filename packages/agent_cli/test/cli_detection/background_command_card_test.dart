import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// **A background Bash call's row says what the command did, not the CLI's
/// launch notice**, and the agent's Read of the task's output file folds into
/// that row. Shapes are Claude Code 2.1.287's (2026-10-06); paths synthetic.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bg_cmd'));
  tearDown(() => removeTempDirectory(root));

  const task = 'b5a1yjvrz';
  const outputFile =
      r'C:\Users\someone\AppData\Local\Temp\claude\proj\sess\tasks\'
      '$task.output';

  String path() => '${root.path}/s1.jsonl';
  Future<List<TranscriptMessage>> read(List<Object> lines) {
    File(path()).writeAsStringSync(lines.map(jsonEncode).join('\n'));
    return readCliTranscript(path(), AgentIds.claudeCode);
  }

  Map<String, Object?> assistant(String at, Map<String, Object?> part) => {
    'type': 'assistant',
    'timestamp': at,
    'message': {
      'role': 'assistant',
      'content': [part],
    },
  };

  Map<String, Object?> result(
    String at,
    String id,
    Object content,
    Object toolUseResult,
  ) => {
    'type': 'user',
    'timestamp': at,
    'message': {
      'role': 'user',
      'content': [
        {
          'tool_use_id': id,
          'type': 'tool_result',
          'content': content,
          'is_error': false,
        },
      ],
    },
    'toolUseResult': toolUseResult,
  };

  final call = assistant('2026-10-06T04:39:30.000Z', {
    'type': 'tool_use',
    'id': 'toolu_bash',
    'name': 'Bash',
    'input': {
      'command': 'echo hi',
      'description': 'Say hi',
      'run_in_background': true,
    },
  });

  final launched = result(
    '2026-10-06T04:39:31.000Z',
    'toolu_bash',
    'Command running in background with ID: $task. Output is being written '
        'to: $outputFile. You will be notified when it completes. To check '
        'interim output, use Read on that file path.',
    {
      'stdout': '',
      'stderr': '',
      'interrupted': false,
      'backgroundTaskId': task,
    },
  );

  Map<String, Object?> notice(int code) => {
    'type': 'user',
    'timestamp': '2026-10-06T04:39:35.000Z',
    'message': {
      'role': 'user',
      'content':
          '<task-notification>\n<task-id>$task</task-id>\n'
          '<tool-use-id>toolu_bash</tool-use-id>\n'
          '<output-file>$outputFile</output-file>\n'
          '<status>${code == 0 ? 'completed' : 'failed'}</status>\n'
          '<summary>Background command "Say hi" '
          '${code == 0 ? 'completed' : 'failed'} (exit code $code)</summary>\n'
          '</task-notification>',
    },
  };

  final readCall = assistant('2026-10-06T04:39:40.000Z', {
    'type': 'tool_use',
    'id': 'toolu_read',
    'name': 'Read',
    'input': {'file_path': outputFile},
  });

  final readResult = result(
    '2026-10-06T04:39:40.200Z',
    'toolu_read',
    '1\thi\n2\t',
    {
      'type': 'text',
      'file': {
        'filePath': outputFile,
        'content': 'hi\n',
        'numLines': 2,
        'startLine': 1,
        'totalLines': 2,
      },
    },
  );

  void expectNoTempPath(List<TranscriptMessage> rows) {
    // The notice's own row is drawn from its summary (taskNotificationLine).
    for (final row in rows.where((r) => r.tool != null)) {
      for (final text in [row.text, row.tool?.subject, row.tool?.output]) {
        expect(text ?? '', isNot(contains('tasks')), reason: '$text');
        expect(text ?? '', isNot(contains('Output is being written')));
      }
    }
  }

  test('while it runs, the row says it runs in the background', () async {
    final rows = await read([call, launched]);
    final bash = rows.singleWhere((r) => r.tool?.name == 'Bash');
    expect(bash.tool!.output, 'Running in the background');
    expectNoTempPath(rows);
  });

  test('once it ends, the row has its exit code and the output the agent '
      'read, and that Read folds into it', () async {
    final rows = await read([call, launched, notice(0), readCall, readResult]);
    final bash = rows.singleWhere((r) => r.tool?.name == 'Bash');
    expect(bash.tool!.output, 'Exit code 0\nhi');
    final readRow = rows.singleWhere((r) => r.tool?.name == 'Read');
    expect(readRow.parentToolUseId, 'toolu_bash');
    expect(readRow.tool!.subject, 'the output of echo hi');
    expectNoTempPath(rows);
  });

  test('a run that ended unread says its exit code alone', () async {
    final rows = await read([call, launched, notice(2)]);
    final bash = rows.singleWhere((r) => r.tool?.name == 'Bash');
    expect(bash.tool!.output, 'Exit code 2');
    expectNoTempPath(rows);
  });
}
