import 'dart:io';

import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
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

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'user:hi there',
      'agent:hello',
      'tool:Bash',
    ]);
  });

  // The owner's report — "when commands are run … it feels like the command is
  // printed twice" — is this: every Bash call rendered the identical string
  // `tool: Bash`, because the call's own command was thrown away here. A real
  // 265-message transcript held 23 pairs of adjacent, byte-identical tool rows
  // standing for entirely different commands.
  test('a tool call keeps the command it ran', () async {
    final file = write('claude.jsonl', [
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t1","name":"Bash","input":{"command":"git status --short",'
          '"description":"check the tree"}}]}}',
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t2","name":"Bash","input":{"command":"git log -1"}}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => m.tool?.subject), [
      'git status --short',
      'git log -1',
    ]);
    expect(messages.map((m) => m.text), isNot([messages.first.text, messages.first.text]));
  });

  test('a file read keeps the file, and only an image keeps an image', () async {
    final file = write('claude.jsonl', [
      r'{"type":"assistant","message":{"content":[{"type":"tool_use",'
          r'"id":"t1","name":"Read","input":{"file_path":"/repo/lib/main.dart"}}]}}',
      r'{"type":"assistant","message":{"content":[{"type":"tool_use",'
          r'"id":"t2","name":"Read","input":{"file_path":"/repo/.scr.PNG"}}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.map((m) => m.tool?.subject), [
      '/repo/lib/main.dart',
      '/repo/.scr.PNG',
    ]);
    expect(messages.map((m) => m.tool?.imagePath), [null, '/repo/.scr.PNG']);
  });

  test('parses a Codex rollout into user/agent messages', () async {
    final file = write('rollout.jsonl', [
      '{"type":"session_meta","payload":{"id":"x","cwd":"/w"}}',
      '{"type":"response_item","payload":{"type":"message","role":"user",'
          '"content":[{"type":"input_text","text":"do the thing"}]}}',
      '{"type":"response_item","payload":{"type":"message","role":"assistant",'
          '"content":[{"type":"output_text","text":"done"}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.codex);

    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'user:do the thing',
      'agent:done',
    ]);
  });

  test('returns empty for a missing file', () async {
    final messages = await readCliTranscript(
      '${dir.path}/nope.jsonl',
      AgentIds.claudeCode,
    );
    expect(messages, isEmpty);
  });
}
