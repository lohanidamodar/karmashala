import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// Codex's reader takes its own `$visualize` marker out of the answer a
/// person reads; the artifact it names is drawn as a card instead.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('codex_visualize'));
  tearDown(() => removeTempDirectory(dir));

  Future<List<String>> read(String text, {String role = 'assistant'}) async {
    final file = File('${dir.path}/rollout.jsonl')
      ..writeAsStringSync(
        jsonEncode({
          'timestamp': '2026-10-06T10:00:00.000Z',
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': role,
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          },
        }),
      );
    final messages = await readCliTranscript(file.path, AgentIds.codex);
    return [for (final m in messages) '${m.role}:${m.text}'];
  }

  test('the marker is taken out of the agent\'s answer', () async {
    expect(
      await read('Here is the chart.\n\nvisualize{"path":"/w/chart.html"}'),
      ['agent:Here is the chart.'],
    );
  });

  test('a person\'s own words are left as typed', () async {
    const typed = 'What does visualize{"path":"/w/a.html"} do?';
    expect(await read(typed, role: 'user'), ['user:$typed']);
  });
}
