import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// The recap Claude Code writes for someone coming back to a session.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('away_test'));
  tearDown(() => removeTempDirectory(dir));

  test('a recap for someone who was away is a note', () async {
    final file = File('${dir.path}/t.jsonl')
      ..writeAsStringSync(
        jsonEncode({
          'type': 'system',
          'subtype': 'away_summary',
          'content': 'Fixed the parser; tests pass.',
          'isMeta': false,
        }),
      );

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'notice:While you were away: Fixed the parser; tests pass.',
    ]);
  });
}
