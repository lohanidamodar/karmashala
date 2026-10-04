import 'dart:io';

import 'package:agent_cli/src/agents/codex/codex_store_reader.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/cli_detection/data/cli_transcript_reader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/temp_directory.dart';

/// **What Codex writes into its rollout that nobody said** — its skills list,
/// permissions, `<environment_context>` and AGENTS.md block — is not a turn.
/// The fixture keeps the shapes of a Codex CLI 0.160 rollout, shortened.
void main() {
  const fixture = 'test/agents/codex/fixtures/rollout-injected-context.jsonl';

  test('the chat skips injected context and keeps what was said', () async {
    final messages = await readCliTranscript(fixture, AgentIds.codex);
    expect(messages.map((m) => '${m.role}:${m.text}'), [
      'user:Do not use any tools. Reply with exactly DONE-1.',
      'agent:DONE-1',
      'user:<environment_context>is a tag I made up; explain what it would '
          'mean</environment_context>',
      'user:<b>bold</b> — why does this XML not render?',
      'agent:DONE-CLOCKS',
    ]);
  });

  test('the last thing the agent said is its answer, not an instruction '
      'block', () async {
    final messages = await readCliTranscript(fixture, AgentIds.codex);
    expect(messages.lastWhere((m) => m.role == 'agent').text, 'DONE-CLOCKS');
    expect(
      messages.where((m) => m.text.contains('skills_instructions')),
      isEmpty,
    );
  });

  group('an imported conversation is titled by what the person typed', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('codex_injected_'));
    tearDown(() => removeTempDirectory(tmp));

    test('not by the AGENTS.md block', () async {
      final rollout = File(
        p.join(
          tmp.path,
          '.codex/sessions/2026/10/03/'
          'rollout-2026-10-03T08-43-34-01a0ffb2-0000-7e32-86af-000000000001.jsonl',
        ),
      )..createSync(recursive: true);
      rollout.writeAsStringSync(File(fixture).readAsStringSync());

      final sessions = await CodexStoreReader(
        cache: CodexRolloutCache(),
      ).read(p.join(tmp.path, '.codex'), 'local');
      expect(
        sessions.single.preview,
        'Do not use any tools. Reply with exactly DONE-1.',
      );
    });
  });

  test('a preview cut short is still known by how it opens', () {
    expect(
      codexInjectedContext.opensInjected(
        '# AGENTS.md instructions for C:\\work\\app\n\n<INSTRUCTIONS>\n## Sk',
      ),
      isTrue,
    );
    expect(
      codexInjectedContext.opensInjected('<environment_context>\n  <cwd>C:'),
      isTrue,
    );
    expect(
      codexInjectedContext.opensInjected('# AGENTS.md instructions are odd'),
      isFalse,
    );
    expect(codexInjectedContext.opensInjected('fix the cart'), isFalse);
  });
}
