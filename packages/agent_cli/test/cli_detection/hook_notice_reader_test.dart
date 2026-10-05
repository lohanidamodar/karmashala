import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// What Claude Code's hooks said, as its transcript records them: attachment
/// rows per hook run and the Stop hook's `system/stop_hook_summary`. Shapes
/// are the recorded ones (and, for the kinds never seen here, the CLI's own
/// constructors); the text is made up.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('hook_notice_test'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<String>> read(List<Map<String, Object?>> records) async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(records.map(jsonEncode).join('\n'));
    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);
    return [for (final m in messages) '${m.role}:${m.text}'];
  }

  Map<String, Object?> attachment(Map<String, Object?> body) => {
    'type': 'attachment',
    'attachment': body,
  };

  test('a hook that succeeded says nothing', () async {
    expect(
      await read([
        attachment({
          'type': 'hook_success',
          'hookName': 'PostToolUse:Bash',
          'hookEvent': 'PostToolUse',
          'toolUseID': 'toolu_1',
          'command': 'notify.sh',
          'content': '',
          'stdout': '',
          'stderr': '',
          'exitCode': 0,
          'durationMs': 12,
        }),
        attachment({
          'type': 'hook_additional_context',
          'hookName': 'SessionStart',
          'hookEvent': 'SessionStart',
          'toolUseID': 'x',
          'content': ['context for the model'],
        }),
      ]),
      isEmpty,
    );
  });

  test('a hook\'s system message, block and errors are notes', () async {
    expect(
      await read([
        attachment({
          'type': 'hook_system_message',
          'hookName': 'PostToolUse:Bash',
          'hookEvent': 'PostToolUse',
          'toolUseID': 'toolu_1',
          'content': 'hook says hi',
        }),
        attachment({
          'type': 'hook_blocking_error',
          'hookName': 'PreToolUse:Bash',
          'hookEvent': 'PreToolUse',
          'toolUseID': 'toolu_2',
          'blockingError': {
            'blockingError': 'rm is not allowed',
            'command': 'guard.sh',
          },
        }),
        attachment({
          'type': 'hook_non_blocking_error',
          'hookName': 'PostToolUse:Edit',
          'hookEvent': 'PostToolUse',
          'toolUseID': 'toolu_3',
          'stderr': 'formatter crashed',
          'stdout': '',
          'exitCode': 1,
          'command': 'fmt.sh',
        }),
        attachment({
          'type': 'hook_stopped_continuation',
          'hookName': 'PostToolUse:Bash',
          'hookEvent': 'PostToolUse',
          'toolUseID': 'toolu_4',
          'message': 'budget spent',
        }),
        attachment({
          'type': 'hook_cancelled',
          'hookName': 'UserPromptSubmit',
          'hookEvent': 'UserPromptSubmit',
          'toolUseID': 'x',
          'timedOut': true,
          'timeoutMs': 60000,
          'command': 'slow.sh',
        }),
      ]),
      [
        'notice:PostToolUse:Bash hook: hook says hi',
        'notice:PreToolUse:Bash hook blocked it: rm is not allowed',
        'notice:PostToolUse:Edit hook failed: formatter crashed',
        'notice:PostToolUse:Bash hook stopped the agent: budget spent',
        'notice:UserPromptSubmit hook timed out',
      ],
    );
  });

  test('a Stop hook\'s errors come from its summary, once', () async {
    Map<String, Object?> summary({
      List<String> errors = const [],
      List<String> feedback = const [],
      bool prevented = false,
      String stopReason = '',
    }) => {
      'type': 'system',
      'subtype': 'stop_hook_summary',
      'hookCount': 1,
      'hookInfos': [
        {'command': 'check.sh', 'durationMs': 30},
      ],
      'hookErrors': errors,
      'hookAdditionalContext': feedback,
      'preventedContinuation': prevented,
      'stopReason': stopReason,
      'hasOutput': errors.isNotEmpty,
      'level': 'suggestion',
      'toolUseID': 'x',
    };

    expect(
      await read([
        summary(),
        // The CLI hides a Stop hook's own error rows: the summary says it.
        attachment({
          'type': 'hook_blocking_error',
          'hookName': 'Stop',
          'hookEvent': 'Stop',
          'toolUseID': 'x',
          'blockingError': {'blockingError': 'tests fail', 'command': 'x'},
        }),
        summary(errors: ['tests fail'], feedback: ['run them again']),
        summary(prevented: true, stopReason: 'stopped by policy'),
      ]),
      [
        'notice:Stop hook error: tests fail\n'
            'Stop hook feedback: run them again',
        'notice:stopped by policy',
      ],
    );
  });
}
