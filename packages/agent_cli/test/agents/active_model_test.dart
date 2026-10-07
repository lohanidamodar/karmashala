import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:test/test.dart';

/// The model each agent's own record says it ran, read from fixtures shaped
/// like the real files: Claude Code names it on every reply, Codex on the
/// opening `session_meta` and every `turn_context`.
void main() {
  const claude = 'test/agents/fixtures/active_model/claude_model_switch.jsonl';
  const codex = 'test/agents/fixtures/active_model/codex_model_switch.jsonl';
  final registry = AgentRegistry.builtIn;

  List<String> lines(String path) => File(path).readAsLinesSync();
  AgentActiveModel reader(String agentId) =>
      registry.adapterFor(agentId)!.activeModel!;

  group('active model', () {
    test('Claude: the newest main-thread reply, past a synthetic error and '
        'a subagent', () {
      expect(
        reader(AgentIds.claudeCode).latestIn(lines(claude)),
        ActiveModelReading(
          'claude-sonnet-5-5',
          at: DateTime.utc(2026, 10, 7, 9, 2, 13),
        ),
      );
    });

    test('Claude: before the switch, the model it started on', () {
      expect(
        reader(AgentIds.claudeCode).latestIn(lines(claude).take(4))?.modelId,
        'claude-opus-5-5',
      );
    });

    test('Codex: the latest turn_context', () {
      expect(
        reader(AgentIds.codex).latestIn(lines(codex)),
        ActiveModelReading(
          'gpt-6-astra-mini',
          at: DateTime.utc(2026, 10, 7, 5, 6),
        ),
      );
    });

    test('Codex: session_meta alone names the model it opened on', () {
      expect(
        reader(AgentIds.codex).latestIn(lines(codex).take(1))?.modelId,
        'gpt-6-astra',
      );
    });

    test('a record that names none reads null, never a default', () {
      final claudeReader = reader(AgentIds.claudeCode);
      expect(claudeReader.latestIn(lines(claude).take(1)), isNull);
      expect(claudeReader.latestIn(const ['not json', '{"model": 3}']), isNull);
    });

    test('Antigravity reads no model', () {
      expect(registry.adapterFor(AgentIds.antigravity)?.activeModel, isNull);
    });
  });

  group('transcript rows carry the model that wrote them', () {
    test("Claude: each agent row names its reply's model", () async {
      final rows = await readCliTranscript(claude, AgentIds.claudeCode);
      expect(
        [
          for (final row in rows)
            if (row.role == 'agent') (row.text, row.model),
        ],
        [
          ('Hi there.', 'claude-opus-5-5'),
          ('Still Opus.', 'claude-opus-5-5'),
          // A subagent's reply is not the session's model.
          ('A subagent.', null),
          ('Sonnet now.', 'claude-sonnet-5-5'),
        ],
      );
      expect(
        rows.where((r) => r.role == 'user').map((r) => r.model),
        everyElement(isNull),
      );
    });

    test("Codex: each agent row names its turn's model", () async {
      final rows = await readCliTranscript(codex, AgentIds.codex);
      expect(
        [
          for (final row in rows)
            if (row.role == 'agent') (row.text, row.model),
        ],
        [
          ('Hi from astra.', 'gpt-6-astra'),
          ('Hi from mini.', 'gpt-6-astra-mini'),
        ],
      );
    });

    test('the wire form keeps it', () {
      const row = TranscriptMessage(
        role: 'agent',
        text: 'x',
        model: 'claude-opus-5-5',
      );
      expect(row.toJson()['model'], 'claude-opus-5-5');
      expect(TranscriptMessage.fromJson(row.toJson()).model, 'claude-opus-5-5');
      expect(
        TranscriptMessage.fromJson(const {'role': 'agent', 'text': 'x'}).model,
        isNull,
      );
    });
  });
}
