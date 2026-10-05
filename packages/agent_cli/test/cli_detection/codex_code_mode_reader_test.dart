import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/sessions/tool_activity.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// Codex 0.15x's code mode: one `exec` custom tool call runs a script, and
/// the rollout records what the script did as `event_msg/item_completed`
/// items between the call and its output. Shapes are the recorded ones; the
/// text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('code_mode_test'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<TranscriptMessage>> read(List<Map<String, Object?>> records) {
    final file = File('${dir.path}/rollout.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    return readCliTranscript(file.path, AgentIds.codex);
  }

  Map<String, Object?> response(Map<String, Object?> payload) => {
    'timestamp': '2026-10-05T10:00:00.000Z',
    'type': 'response_item',
    'payload': payload,
  };

  Map<String, Object?> completed(Map<String, Object?> item) => {
    'timestamp': '2026-10-05T10:00:01.000Z',
    'type': 'event_msg',
    'payload': {
      'type': 'item_completed',
      'thread_id': 'th',
      'turn_id': 'tu',
      'item': item,
      'started_at_ms': 1,
      'completed_at_ms': 2,
    },
  };

  Map<String, Object?> exec(String callId, String script) => response({
    'type': 'custom_tool_call',
    'id': 'ctc_1',
    'status': 'completed',
    'call_id': callId,
    'name': 'exec',
    'input': script,
  });

  Map<String, Object?> execOutput(String callId, [String text = 'ok']) =>
      response({
        'type': 'custom_tool_call_output',
        'call_id': callId,
        'output': [
          {'type': 'input_text', 'text': text},
        ],
      });

  Map<String, Object?> command(
    String cmd, {
    String output = '',
    int exitCode = 0,
  }) => completed({
    'type': 'CommandExecution',
    'id': 'exec-1',
    'process_id': '100',
    'command': ['C:/Program Files/PowerShell/7/pwsh.exe', '-Command', cmd],
    'cwd': 'C:/work',
    'parsed_cmd': [
      {'type': 'unknown', 'cmd': cmd},
    ],
    'source': 'unified_exec_startup',
    'status': 'completed',
    'stdout': output,
    'stderr': '',
    'aggregated_output': output,
    'exit_code': exitCode,
    'duration': {'secs': 0, 'nanos': 5},
    'formatted_output': output,
  });

  const script = 'text(await tools.exec_command({cmd: "git status"}))';

  test('a script\'s command is the row, not the script', () async {
    final messages = await read([
      exec('call_1', script),
      command('git status', output: 'nothing to commit'),
      execOutput('call_1'),
    ]);

    expect(messages, hasLength(1));
    final tool = messages.single.tool!;
    expect(tool.name, 'exec_command');
    expect(tool.subject, 'git status');
    expect(tool.output, 'nothing to commit');
    expect(tool.isError, isFalse);
    expect(messages.single.pendingToolUseId, isNull);
  });

  test('a running script names the tools it calls, never its code', () async {
    final messages = await read([exec('call_1', script)]);

    final tool = messages.single.tool!;
    expect(tool.name, 'exec');
    expect(tool.subject, 'exec_command');
    expect(messages.single.pendingToolUseId, 'call_1');
  });

  test('each thing a script did is its own row', () async {
    final messages = await read([
      exec('call_1', 'await tools.exec_command({}); await tools.apply_patch()'),
      command('cmd /c exit 3', output: 'boom', exitCode: 3),
      completed({
        'type': 'FileChange',
        'id': 'patch-1',
        'changes': {
          'C:/work/hello.txt': {'type': 'add', 'content': 'hi\n'},
          'C:/work/a.dart': {
            'type': 'update',
            'unified_diff': '@@ -1 +1 @@\n-old\n+new\n',
            'move_path': null,
          },
        },
        'status': 'completed',
        'stdout': 'Success.',
      }),
      completed({
        'type': 'ImageView',
        'id': 'view-1',
        'path': 'C:/work/shot.png',
      }),
      execOutput('call_1'),
    ]);

    expect(messages.map((m) => m.tool?.name), [
      'exec_command',
      'apply_patch',
      'view_image',
    ]);
    expect(messages[0].tool!.isError, isTrue);
    expect(messages[0].tool!.output, 'Exit code 3\nboom');
    expect(messages[1].tool!.edits.map((e) => (e.path, e.kind)), [
      ('C:/work/hello.txt', FileEditKind.created),
      ('C:/work/a.dart', FileEditKind.modified),
    ]);
    expect(messages[1].tool!.subject, 'C:/work/hello.txt');
    expect(messages[2].tool!.imagePath, 'C:/work/shot.png');
    expect(messages.every((m) => m.pendingToolUseId == null), isTrue);
  });

  test('a script that did nothing visible keeps its own answer', () async {
    final messages = await read([
      exec('call_1', 'text(ALL_TOOLS.map((t) => t.name))'),
      execOutput('call_1', 'exec_command, apply_patch'),
    ]);

    expect(messages.single.tool!.name, 'exec');
    expect(messages.single.tool!.subject, isNull);
    expect(messages.single.tool!.output, 'exec_command, apply_patch');
  });

  test('a command that outlived its script still gets a row', () async {
    final messages = await read([
      exec('call_1', script),
      execOutput('call_1', 'still running'),
      command('npm test', output: 'passed'),
    ]);

    expect(messages.map((m) => (m.tool?.name, m.tool?.subject)), [
      ('exec', 'exec_command'),
      ('exec_command', 'npm test'),
    ]);
  });

  test('a patch call is not drawn twice by its completed item', () async {
    final messages = await read([
      response({
        'type': 'custom_tool_call',
        'call_id': 'call_1',
        'name': 'apply_patch',
        'input':
            '*** Begin Patch\n*** Add File: hello.txt\n+hi\n*** End Patch\n',
      }),
      completed({
        'type': 'FileChange',
        'id': 'patch-1',
        'changes': {
          'hello.txt': {'type': 'add', 'content': 'hi\n'},
        },
        'status': 'completed',
        'stdout': 'Success.',
      }),
      response({
        'type': 'custom_tool_call_output',
        'call_id': 'call_1',
        'output': 'Success.',
      }),
    ]);

    expect(messages.single.tool!.name, 'apply_patch');
  });

  test('MCP calls, searches and generated images inside a script', () async {
    final messages = await read([
      exec('call_1', 'await tools.mcp__docs__lookup({})'),
      completed({
        'type': 'McpToolCall',
        'id': 'mcp-1',
        'server': 'docs',
        'tool': 'lookup',
        'arguments': {'query': 'records'},
        'status': 'completed',
        'result': {
          'content': [
            {'type': 'text', 'text': 'Records are tuples.'},
          ],
          'isError': false,
        },
        'duration': {'secs': 0, 'nanos': 1},
      }),
      completed({
        'type': 'WebSearch',
        'id': 'ws-1',
        'query': 'dart records',
        'action': {
          'type': 'search',
          'queries': ['dart records'],
        },
        'results': [
          {
            'type': 'text_result',
            'domain': 'dart.dev',
            'ref_id': 'turn0search0',
            'snippet': 'About records.',
            'title': 'Records',
            'url': 'https://dart.dev/records',
          },
        ],
      }),
      completed({
        'type': 'Extension',
        'kind': 'image_gen.generation',
        'id': 'ig-1',
        'status': 'completed',
        'revisedPrompt': 'A red square on white.',
        'result': 'aGVsbG8=',
        'transparentBackground': null,
        'failure': null,
        'savedPath': 'C:/Users/me/.codex/images/square.png',
      }),
      completed({
        'type': 'Extension',
        'kind': 'clock.sleep',
        'id': 'sl-1',
        'durationMs': 1000,
      }),
      execOutput('call_1'),
    ]);

    expect(messages.map((m) => (m.tool?.name, m.tool?.subject)), [
      ('mcp__docs__lookup', 'records'),
      ('web_search', 'dart records'),
      ('image_gen', 'A red square on white.'),
    ]);
    expect(messages[0].tool!.output, 'Records are tuples.');
    expect(messages[1].tool!.output, contains('https://dart.dev/records'));
    expect(messages[2].tool!.imagePath, 'C:/Users/me/.codex/images/square.png');
    expect(messages[2].tool!.output, isNull);
  });

  test(
    'messages and reasoning items do not repeat the response items',
    () async {
      final messages = await read([
        completed({
          'type': 'AgentMessage',
          'id': 'item-3',
          'content': [
            {'type': 'Text', 'text': 'Hello.'},
          ],
        }),
        response({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Hello.'},
          ],
        }),
      ]);

      expect(messages.map((m) => m.text), ['Hello.']);
    },
  );
}
