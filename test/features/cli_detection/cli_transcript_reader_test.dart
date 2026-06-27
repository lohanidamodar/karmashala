import 'dart:io';

import 'package:chitragupta/src/features/agents/domain/agent_kind.dart';
import 'package:chitragupta/src/features/cli_detection/data/cli_transcript_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcript_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<String> lines) {
    final file = File('${dir.path}/$name');
    file.writeAsStringSync(lines.join('\n'));
    return file;
  }

  test('parses a Claude transcript into user/agent/tool messages', () async {
    final file = write('claude.jsonl', [
      '{"type":"user","message":{"role":"user","content":"hi there"}}',
      '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"},'
          '{"type":"tool_use","name":"Bash"}]}}',
      'not json',
      '{"type":"summary"}',
    ]);

    final messages = await readCliTranscript(file.path, AgentKind.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'user:hi there',
      'agent:hello',
      'tool:tool: Bash',
    ]);
  });

  test('parses a Codex rollout into user/agent messages', () async {
    final file = write('rollout.jsonl', [
      '{"type":"session_meta","payload":{"id":"x","cwd":"/w"}}',
      '{"type":"response_item","payload":{"type":"message","role":"user",'
          '"content":[{"type":"input_text","text":"do the thing"}]}}',
      '{"type":"response_item","payload":{"type":"message","role":"assistant",'
          '"content":[{"type":"output_text","text":"done"}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentKind.codex);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'user:do the thing',
      'agent:done',
    ]);
  });

  test('returns empty for a missing file', () async {
    final messages = await readCliTranscript(
      '${dir.path}/nope.jsonl',
      AgentKind.claudeCode,
    );
    expect(messages, isEmpty);
  });
}
