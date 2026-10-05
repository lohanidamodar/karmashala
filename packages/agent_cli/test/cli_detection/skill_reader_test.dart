import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// A Skill call names its skill, and the body Claude Code loads after it (an
/// isMeta turn nobody typed) is the call's output, folded like any other.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('skill_test'));
  tearDown(() => removeTempDirectory(dir));

  test('a Skill row names the skill and holds its body', () async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(
        [
          {
            'type': 'assistant',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'id': 't1',
                  'name': 'Skill',
                  'input': {'skill': 'demo:checklist'},
                },
              ],
            },
          },
          {
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 't1',
                  'content': 'Launching skill: demo:checklist',
                },
              ],
            },
            'toolUseResult': {'success': true, 'commandName': 'demo:checklist'},
          },
          {
            'type': 'user',
            'isMeta': true,
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text':
                      'Base directory for this skill: /skills/checklist\n\n'
                      '# Checklist\n\nWork down the list.',
                },
              ],
            },
          },
        ].map(jsonEncode).join('\n'),
      );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    final skill = messages.single.tool!;
    expect(skill.subject, 'demo:checklist');
    expect(skill.output, contains('# Checklist'));
    expect(skill.output, isNot(contains('Base directory')));
  });
}
