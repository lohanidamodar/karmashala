import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// The two facts the app and the server used to read off an agent's id —
/// how its TUI measures text and takes typing, and which imported records
/// were never conversations — asked of the agent instead.
void main() {
  AgentAdapter adapter(String id) => AgentRegistry.builtIn.adapterFor(id)!;

  group('terminal rules', () {
    test('Claude Code measures a cluster by its base; nobody else does', () {
      expect(
        adapter(AgentIds.claudeCode).descriptor.terminal.clusterWidthFromBase,
        isTrue,
      );
      expect(
        adapter(AgentIds.codex).descriptor.terminal.clusterWidthFromBase,
        isFalse,
      );
      expect(
        adapter(AgentIds.antigravity).descriptor.terminal.clusterWidthFromBase,
        isFalse,
      );
    });

    test(
      'Codex folds a typed Return into its paste burst; nobody else does',
      () {
        expect(
          adapter(AgentIds.codex).descriptor.terminal.pasteBurstFoldsReturn,
          isTrue,
        );
        expect(
          adapter(
            AgentIds.claudeCode,
          ).descriptor.terminal.pasteBurstFoldsReturn,
          isFalse,
        );
      },
    );

    test('an agent nobody measured is a shell', () {
      const rules = AgentTerminalRules();
      expect(rules.clusterWidthFromBase, isFalse);
      expect(rules.pasteBurstFoldsReturn, isFalse);
      expect(rules.typedTextArrivesWhole, isFalse);
      expect(rules.takesInputMidTurn, isFalse);
    });

    test('Claude Code and Codex take input typed mid-turn; Antigravity is '
        'unmeasured', () {
      for (final id in [AgentIds.claudeCode, AgentIds.codex]) {
        expect(adapter(id).descriptor.terminal.takesInputMidTurn, isTrue);
      }
      expect(
        adapter(AgentIds.antigravity).descriptor.terminal.takesInputMidTurn,
        isFalse,
      );
    });

    test('Claude Code and Codex name the placeholder a long paste shows as; '
        'an unmeasured agent names none', () {
      expect(
        adapter(AgentIds.claudeCode).descriptor.terminal.pastePlaceholder,
        '[Pasted text #',
      );
      expect(
        adapter(AgentIds.codex).descriptor.terminal.pastePlaceholder,
        '[Pasted Content ',
      );
      expect(
        adapter(AgentIds.antigravity).descriptor.terminal.pastePlaceholder,
        isNull,
      );
      expect(const AgentTerminalRules().pastePlaceholder, isNull);
    });

    test('a long typed message reaches Claude Code whole; unmeasured '
        'elsewhere', () {
      expect(
        adapter(AgentIds.claudeCode).descriptor.terminal.typedTextArrivesWhole,
        isTrue,
      );
      expect(
        adapter(AgentIds.antigravity).descriptor.terminal.typedTextArrivesWhole,
        isFalse,
      );
    });
  });

  group('system prompt', () {
    test('Claude Code takes the packet as text as well as a file', () {
      final support = adapter(
        AgentIds.claudeCode,
      ).descriptor.launch.systemPromptFile;
      expect(support.argumentsForText('brief\nline'), [
        '--append-system-prompt',
        'brief\nline',
      ]);
      expect(support.argumentsFor('/tmp/x.md'), [
        '--append-system-prompt-file',
        '/tmp/x.md',
      ]);
    });

    test('an agent with no inline option takes no text', () {
      final support = adapter(
        AgentIds.codex,
      ).descriptor.launch.systemPromptFile;
      expect(support.takesText, isFalse);
      expect(support.argumentsForText('brief'), isEmpty);
    });
  });

  group('import audit', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('import_audit_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String rollout(String name, String firstLine) {
      final file = File('${dir.path}/$name')..writeAsStringSync('$firstLine\n');
      return file.path;
    }

    test('only Codex has one', () {
      expect(adapter(AgentIds.codex).importAudit, isNotNull);
      expect(adapter(AgentIds.claudeCode).importAudit, isNull);
      expect(adapter(AgentIds.antigravity).importAudit, isNull);
    });

    test(
      'a Codex rollout is a run only when its own session_meta says so',
      () async {
        final audit = adapter(AgentIds.codex).importAudit!;
        Future<bool> run(String path) => audit.isNotConversation(path);

        expect(
          await run(
            rollout(
              'exec.jsonl',
              '{"type":"session_meta","payload":{"source":"exec"}}',
            ),
          ),
          isTrue,
        );
        expect(
          await run(
            rollout(
              'sub.jsonl',
              '{"type":"session_meta","payload":{"source":{"subagent":"x"}}}',
            ),
          ),
          isTrue,
        );
        expect(
          await run(
            rollout(
              'cli.jsonl',
              '{"type":"session_meta","payload":{"source":"cli"}}',
            ),
          ),
          isFalse,
        );
        expect(
          await run(
            rollout('old.jsonl', '{"type":"session_meta","payload":{}}'),
          ),
          isFalse,
          reason: 'an older rollout records no source: a conversation',
        );
        expect(await run(rollout('odd.jsonl', 'not json')), isFalse);
        expect(
          await run('${dir.path}/missing.jsonl'),
          isFalse,
          reason: 'nothing is taken on a guess',
        );
        expect(audit.recordNoun, 'Codex run');
      },
    );
  });
}
