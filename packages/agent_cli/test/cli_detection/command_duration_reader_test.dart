import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:agent_cli/src/sessions/tool_activity.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// A call's answer keeps the time its own line was written, so a command's
/// duration is the record's, not a guess; a line with no time gives none.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('duration_test'));
  tearDown(() => removeTempDirectory(dir));

  File write(String name, List<String> lines) =>
      File('${dir.path}/$name')..writeAsStringSync(lines.join('\n'));

  test("Claude's tool_result stamps the call's end", () async {
    final file = write('claude.jsonl', [
      '{"type":"assistant","timestamp":"2026-10-08T10:00:00.000Z",'
          '"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash",'
          '"input":{"command":"dart test"}}]}}',
      '{"type":"user","timestamp":"2026-10-08T10:00:02.400Z",'
          '"message":{"role":"user","content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":"All tests passed!"}]}}',
    ]);
    final row = (await readCliTranscript(
      file.path,
      AgentIds.claudeCode,
    )).single;
    expect(row.at, DateTime.utc(2026, 10, 8, 10));
    expect(row.tool!.endedAt, DateTime.utc(2026, 10, 8, 10, 0, 2, 400));
  });

  test("Codex's function_call_output stamps the call's end", () async {
    final file = write('rollout.jsonl', [
      '{"type":"response_item","timestamp":"2026-10-08T10:00:00.000Z",'
          '"payload":{"type":"function_call","name":"shell","call_id":"c1",'
          '"arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"ls\\"]}"}}',
      '{"type":"response_item","timestamp":"2026-10-08T10:01:12.000Z",'
          '"payload":{"type":"function_call_output","call_id":"c1",'
          '"output":"a\\nb"}}',
    ]);
    final row = (await readCliTranscript(file.path, AgentIds.codex)).single;
    expect(
      row.tool!.endedAt!.difference(row.at!),
      const Duration(minutes: 1, seconds: 12),
    );
  });

  test('a result line with no time leaves no end', () async {
    final file = write('claude.jsonl', [
      '{"type":"assistant","timestamp":"2026-10-08T10:00:00.000Z",'
          '"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash",'
          '"input":{"command":"ls"}}]}}',
      '{"type":"user","message":{"role":"user","content":[{"type":"tool_result",'
          '"tool_use_id":"t1","content":"x"}]}}',
    ]);
    final row = (await readCliTranscript(
      file.path,
      AgentIds.claudeCode,
    )).single;
    expect(row.tool!.output, 'x');
    expect(row.tool!.endedAt, isNull);
  });

  test('the end crosses the wire and survives a plan', () {
    final ended = DateTime.utc(2026, 10, 8, 10, 0, 3);
    final call = const ToolActivity(
      name: 'Bash',
    ).withResult(output: 'ok', endedAt: ended);
    expect(ToolActivity.fromJson(call.toJson()).endedAt, ended);
    expect(
      ToolActivity.fromJson(const ToolActivity(name: 'Bash').toJson()).endedAt,
      isNull,
    );
  });
}
