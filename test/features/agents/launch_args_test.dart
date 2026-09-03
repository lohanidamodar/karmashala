import 'package:karmashala/src/features/agents/data/antigravity_adapter.dart';
import 'package:karmashala/src/features/agents/data/claude_code_adapter.dart';
import 'package:karmashala/src/features/agents/data/codex_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  AgentPermissionSupport supportFor(String agentId) =>
      AgentRegistry.builtIn.byId(agentId)!.launch.permission;

  /// A launch of [agentId] under the mode stored as [stored], resolved the way
  /// the real callers resolve it.
  ///
  /// The adapters no longer carry a flag table of their own — they emit
  /// `launch.permission.arguments` — so the mode is resolved against the
  /// descriptor before it ever reaches one. Resolving from the **registry**
  /// rather than from a literal is what keeps the assertions below able to
  /// fail: the flags they expect are still written out by hand, so a descriptor
  /// that stopped naming `manual` would move one side of the comparison only.
  /// `stored: null` is "nobody chose", which is the agent's declared default.
  AgentLaunch launch(String agentId, {String? stored, String? resume}) {
    final support = supportFor(agentId);
    return AgentLaunch(
      workingDirectory: repository().path,
      installation: agentInstallation(),
      permission: ResolvedPermission.of(support, support.resolveStored(stored)),
      resumeSessionId: resume,
    );
  }

  group('claudeLaunchArgs', () {
    test('the default names the manual mode rather than passing nothing', () {
      // This asserted `isNot(contains('--permission-mode'))` until a real CLI
      // contradicted it: an unflagged session starts in `auto` on a
      // Pro/Max/Team account, so "no flag" silently was not "ask".
      expect(
        claudeLaunchArgs(launch(AgentIds.claudeCode)),
        containsAllInOrder(['--permission-mode', 'manual']),
      );
    });
    test('acceptEdits and bypass map to --permission-mode', () {
      expect(
        claudeLaunchArgs(
          launch(AgentIds.claudeCode, stored: 'mode=acceptEdits'),
        ),
        containsAllInOrder(['--permission-mode', 'acceptEdits']),
      );
      expect(
        claudeLaunchArgs(
          launch(AgentIds.claudeCode, stored: 'mode=bypassPermissions'),
        ),
        containsAllInOrder(['--permission-mode', 'bypassPermissions']),
      );
    });
    test('resume adds --resume <id>', () {
      expect(
        claudeLaunchArgs(launch(AgentIds.claudeCode, resume: 'sid')),
        containsAllInOrder(['--resume', 'sid']),
      );
    });
  });

  group('codexLaunchArgs', () {
    test('maps permission to approval/sandbox flags', () {
      // Both axes reach the command line, in axis order.
      expect(
        codexLaunchArgs(launch(AgentIds.codex)),
        containsAllInOrder([
          '--sandbox',
          'workspace-write',
          '--ask-for-approval',
          'on-request',
        ]),
      );
      // And the one flag that replaces both, which supersedes the approval
      // axis rather than joining it.
      final bypass = codexLaunchArgs(
        launch(AgentIds.codex, stored: 'sandbox=bypass-all'),
      );
      expect(bypass, contains('--dangerously-bypass-approvals-and-sandbox'));
      expect(bypass, isNot(contains('--ask-for-approval')));
    });
    test('resume adds --resume <id>', () {
      expect(
        codexLaunchArgs(launch(AgentIds.codex, resume: 'sid')),
        containsAllInOrder(['--resume', 'sid']),
      );
    });
  });

  group('antigravityLaunchArgs', () {
    test('an unflagged launch is how the CLI already asks', () {
      // `agy` prompts before tool use unless told otherwise, so the safe mode
      // is the empty command line rather than a missing flag — and it is the
      // declared default, not the absence of one.
      expect(antigravityLaunchArgs(launch(AgentIds.antigravity)), isEmpty);
    });

    test('accept-edits and bypass use the flags agy --help documents', () {
      expect(
        antigravityLaunchArgs(
          launch(AgentIds.antigravity, stored: 'mode=accept-edits'),
        ),
        containsAllInOrder(['--mode', 'accept-edits']),
      );
      expect(
        antigravityLaunchArgs(
          launch(AgentIds.antigravity, stored: 'mode=skip-permissions'),
        ),
        contains('--dangerously-skip-permissions'),
      );
    });

    test('resume names the conversation by id', () {
      expect(
        antigravityLaunchArgs(launch(AgentIds.antigravity, resume: 'sid')),
        containsAllInOrder(['--conversation', 'sid']),
      );
    });

    test('the retired guesses are gone', () {
      // `--stdio`, `--yolo` and `--resume` were invented against a fake process
      // and are not flags this CLI has. A wrong flag does not fail loudly — it
      // makes the agent refuse to launch. Every mode the descriptor declares is
      // checked, not the three of a shared enum.
      for (final selection in supportFor(AgentIds.antigravity).selections()) {
        final args = antigravityLaunchArgs(
          launch(
            AgentIds.antigravity,
            stored: selection.canonical,
            resume: 's',
          ),
        );
        expect(args, isNot(contains('--stdio')), reason: selection.canonical);
        expect(args, isNot(contains('--yolo')), reason: selection.canonical);
        expect(args, isNot(contains('--resume')), reason: selection.canonical);
      }
    });
  });
}
