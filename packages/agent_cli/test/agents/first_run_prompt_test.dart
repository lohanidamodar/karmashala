import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// The rows Claude Code draws at its folder-trust question, as the host's
/// screen reads them — the wording of `claude-code-trust-prompt.raw`, seen
/// again live on 2026-09-25 under an automation nobody was watching.
const _claudeTrust = [
  '────────────────────────────────────────────────────────────────────',
  ' Accessing workspace:',
  '',
  ' /Users/me/src/fresh-checkout',
  '',
  ' Quick safety check: Is this a project you created or one you trust? (Like your',
  ' own code, a well-known open source project, or work from your team). If not,',
  " take a moment to review what's in this folder first.",
  '',
  " Claude Code'll be able to read, edit, and execute files here.",
  '',
  ' Security guide',
  '',
  ' ❯ 1. No, exit',
  '   2. Yes, I trust this folder',
  '',
  ' Enter to confirm · Esc to cancel',
];

/// Codex's directory-trust question, from `codex-approval-prompt.raw`.
const _codexTrust = [
  '> You are in /Users/me/src/fresh-checkout',
  '',
  '  Do you trust the contents of this directory? Working with untrusted',
  '  contents comes with higher risk of prompt injection.',
  '',
  '› 1. Yes, continue',
  '  2. No, quit',
  '',
  '  Press enter to continue',
];

/// A tool-permission modal: the same footer as the trust question, and not it.
const _claudePermission = [
  ' Bash command',
  '   rm -rf build',
  ' Do you want to proceed?',
  ' ❯ 1. Yes',
  '   2. No, and tell Claude what to do differently',
  ' Esc to cancel · Tab to amend',
];

void main() {
  AgentFirstRunPromptRules rulesOf(String id) =>
      AgentRegistry.builtIn.byId(id)!.launch.firstRunPrompt;

  group('first-run prompt rules', () {
    test('Claude Code reads its folder-trust question', () {
      expect(rulesOf(AgentIds.claudeCode).matchedBy(_claudeTrust), isTrue);
    });

    test('however the question wraps', () {
      expect(
        rulesOf(AgentIds.claudeCode).matchedBy(const [
          ' Quick safety check: Is this a project you cre',
          'ated or one you trust?',
        ]),
        isTrue,
      );
    });

    test('Codex reads its directory-trust question', () {
      expect(rulesOf(AgentIds.codex).matchedBy(_codexTrust), isTrue);
    });

    test('a permission modal, an idle screen or nothing is not it', () {
      final claude = rulesOf(AgentIds.claudeCode);
      expect(claude.matchedBy(_claudePermission), isFalse);
      expect(claude.matchedBy(const ['❯ ', '⏸ manual mode on']), isFalse);
      expect(claude.matchedBy(const []), isFalse);
      // Codex's update offer shares the trust question's footer.
      expect(
        rulesOf(AgentIds.codex).matchedBy(const [
          '✨ Update available! 0.146.0 -> 0.151.0',
          'Press enter to continue',
        ]),
        isFalse,
      );
    });

    test('an agent that declares no question never matches', () {
      const rules = AgentFirstRunPromptRules();
      expect(rules.isEmpty, isTrue);
      expect(rules.matchedBy(_claudeTrust), isFalse);
    });

    test('only the bottom of the screen is read', () {
      const rules = AgentFirstRunPromptRules(
        markers: [GridMatcher('Yes, I trust this folder')],
        scanLines: 3,
      );
      expect(
        rules.matchedBy([..._claudeTrust, 'one', 'two', 'three']),
        isFalse,
      );
    });
  });
}
