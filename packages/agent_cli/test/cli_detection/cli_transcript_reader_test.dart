import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/sessions/tool_activity.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('transcript_test'));
  tearDown(() => removeTempDirectory(dir));

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

  // The third report: "show the output of terminal commands". Claude Code
  // answers every `tool_use` with a `tool_result` in the next `user` entry —
  // the output was always on disk and was simply dropped here.
  test('a tool result is attached to the call it answers', () async {
    final file = write('claude.jsonl', [
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t1","name":"Bash","input":{"command":"git status"}}]}}',
      '{"type":"user","message":{"role":"user","content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":"nothing to commit","is_error":false}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    // One row, not a tool row followed by a stray "user" turn holding the
    // command's output.
    expect(messages, hasLength(1));
    expect(messages.single.tool?.output, 'nothing to commit');
    expect(messages.single.tool?.isError, isFalse);
  });

  test('a failed call is recorded as failed', () async {
    final file = write('claude.jsonl', [
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t1","name":"Bash","input":{"command":"exit 1"}}]}}',
      '{"type":"user","message":{"role":"user","content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":[{"type":"text","text":"boom"}],'
          '"is_error":true}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.single.tool?.output, 'boom');
    expect(messages.single.tool?.isError, isTrue);
  });

  test('an image result never drags its bytes in with it', () async {
    // A real transcript carried 96 base64 images; this file is re-parsed on a
    // two-second poll, so the bytes stay on disk and the path is what is kept.
    final file = write('claude.jsonl', [
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t1","name":"Read","input":{"file_path":"/repo/shot.png"}}]}}',
      '{"type":"user","message":{"role":"user","content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":[{"type":"text","text":"[Image: 2x2]"},'
          '{"type":"image","source":{"type":"base64","media_type":"image/png",'
          '"data":"SUPERLONGBASE64PAYLOAD"}}]}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.single.tool?.imagePath, '/repo/shot.png');
    expect(messages.single.tool?.output, isNot(contains('SUPERLONG')));
  });

  test('a result too big to hold is kept as a bounded head', () async {
    final huge = 'x' * (kMaxToolOutputBytes + 500);
    final file = write('claude.jsonl', [
      '{"type":"assistant","message":{"content":[{"type":"tool_use",'
          '"id":"t1","name":"Read","input":{"file_path":"/repo/huge.log"}}]}}',
      '{"type":"user","message":{"role":"user","content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":"$huge"}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

    expect(messages.single.tool?.output, hasLength(kMaxToolOutputBytes));
    expect(messages.single.tool?.outputTruncated, isTrue);
  });

  test('a Codex shell call carries its command and its output', () async {
    final file = write('rollout.jsonl', [
      '{"type":"response_item","payload":{"type":"function_call",'
          '"name":"shell","call_id":"c1",'
          '"arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"ls -la\\"]}"}}',
      '{"type":"response_item","payload":{"type":"function_call_output",'
          '"call_id":"c1","output":[{"type":"input_text","text":"total 0"}]}}',
    ]);

    final messages = await readCliTranscript(file.path, AgentIds.codex);

    expect(messages.single.role, 'tool');
    expect(messages.single.tool?.name, 'shell');
    expect(messages.single.tool?.subject, 'bash -lc ls -la');
    expect(messages.single.tool?.output, 'total 0');
  });

  // Everything the live-activity strip stands on is read here: a call is
  // outstanding because the reader says so, and it can be aged out because the
  // line carried its own instant. Both shipped CLIs write `timestamp` on every
  // line, verified against real transcripts on this machine.
  group('what is still outstanding', () {
    test('a Claude call keeps the instant it was issued', () async {
      final file = write('claude.jsonl', [
        '{"type":"assistant","timestamp":"2026-09-02T10:15:30.500Z",'
            '"message":{"content":[{"type":"tool_use",'
            '"id":"t1","name":"Bash","input":{"command":"git status"}}]}}',
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(messages.single.at, DateTime.utc(2026, 9, 2, 10, 15, 30, 500));
      expect(messages.single.at?.isUtc, isTrue);
    });

    test('a Codex call keeps it too, off the same key', () async {
      final file = write('rollout.jsonl', [
        '{"type":"response_item","timestamp":"2026-09-02T10:15:30.000Z",'
            '"payload":{"type":"function_call","name":"shell","call_id":"c1",'
            '"arguments":"{\\"command\\":[\\"ls\\"]}"}}',
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.codex);

      expect(messages.single.at, DateTime.utc(2026, 9, 2, 10, 15, 30));
      expect(messages.single.pendingToolUseId, 'c1');
    });

    test('a line with no timestamp says so rather than guessing', () async {
      final file = write('claude.jsonl', [
        '{"type":"assistant","message":{"content":[{"type":"tool_use",'
            '"id":"t1","name":"Bash","input":{"command":"git status"}}]}}',
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(messages.single.at, isNull);
    });

    test('an unanswered call keeps its id; an answered one drops it', () async {
      final file = write('claude.jsonl', [
        '{"type":"assistant","timestamp":"2026-09-02T10:00:00.000Z",'
            '"message":{"content":[{"type":"tool_use",'
            '"id":"t1","name":"Bash","input":{"command":"git status"}}]}}',
        '{"type":"user","timestamp":"2026-09-02T10:00:02.000Z",'
            '"message":{"role":"user","content":[{"type":"tool_result",'
            '"tool_use_id":"t1","content":"clean"}]}}',
        '{"type":"assistant","timestamp":"2026-09-02T10:00:03.000Z",'
            '"message":{"content":[{"type":"tool_use",'
            '"id":"t2","name":"Bash","input":{"command":"flutter test"}}]}}',
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(messages.map((m) => m.pendingToolUseId), [null, 't2']);
      // The answered row kept the instant it was issued at, not the instant it
      // was answered — elapsed is measured from the call.
      expect(messages.first.at, DateTime.utc(2026, 9, 2, 10));
    });

    // The trap inside the trap: `tool.output` is null for a call that answered
    // with nothing at all, so reading *that* as "still running" would leave a
    // finished call on screen forever.
    test('a call answered with nothing is still answered', () async {
      final file = write('claude.jsonl', [
        '{"type":"assistant","timestamp":"2026-09-02T10:00:00.000Z",'
            '"message":{"content":[{"type":"tool_use",'
            '"id":"t1","name":"Bash","input":{"command":"true"}}]}}',
        '{"type":"user","timestamp":"2026-09-02T10:00:01.000Z",'
            '"message":{"role":"user","content":[{"type":"tool_result",'
            '"tool_use_id":"t1","content":""}]}}',
      ]);

      final messages = await readCliTranscript(file.path, AgentIds.claudeCode);

      expect(messages.single.tool?.output, isNull);
      expect(
        messages.single.pendingToolUseId,
        isNull,
        reason: 'an empty answer is an answer',
      );
    });
  });

  test('returns empty for a missing file', () async {
    final messages = await readCliTranscript(
      '${dir.path}/nope.jsonl',
      AgentIds.claudeCode,
    );
    expect(messages, isEmpty);
  });
}
