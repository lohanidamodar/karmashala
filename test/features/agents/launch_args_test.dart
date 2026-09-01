import 'package:karmashala/src/features/agents/data/antigravity_adapter.dart';
import 'package:karmashala/src/features/agents/data/claude_code_adapter.dart';
import 'package:karmashala/src/features/agents/data/codex_adapter.dart';
import 'package:karmashala/src/features/agents/domain/agent_adapter.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  AgentLaunch launch({
    PermissionMode permission = PermissionMode.ask,
    String? resume,
  }) => AgentLaunch(
    workingDirectory: repository().path,
    installation: agentInstallation(),
    permissionMode: permission,
    resumeSessionId: resume,
  );

  group('claudeLaunchArgs', () {
    test('ask names the manual mode rather than passing nothing', () {
      // This asserted `isNot(contains('--permission-mode'))` until a real CLI
      // contradicted it: an unflagged session starts in `auto` on a
      // Pro/Max/Team account, so "no flag" silently was not "ask".
      expect(
        claudeLaunchArgs(launch()),
        containsAllInOrder(['--permission-mode', 'manual']),
      );
    });
    test('acceptEdits and bypass map to --permission-mode', () {
      expect(
        claudeLaunchArgs(launch(permission: PermissionMode.acceptEdits)),
        containsAllInOrder(['--permission-mode', 'acceptEdits']),
      );
      expect(
        claudeLaunchArgs(launch(permission: PermissionMode.bypass)),
        containsAllInOrder(['--permission-mode', 'bypassPermissions']),
      );
    });
    test('resume adds --resume <id>', () {
      expect(
        claudeLaunchArgs(launch(resume: 'sid')),
        containsAllInOrder(['--resume', 'sid']),
      );
    });
  });

  group('codexLaunchArgs', () {
    test('maps permission to approval/sandbox flags', () {
      expect(
        codexLaunchArgs(launch()),
        containsAllInOrder(['--ask-for-approval', 'on-request']),
      );
      expect(
        codexLaunchArgs(launch(permission: PermissionMode.bypass)),
        contains('--dangerously-bypass-approvals-and-sandbox'),
      );
    });
    test('resume adds --resume <id>', () {
      expect(
        codexLaunchArgs(launch(resume: 'sid')),
        containsAllInOrder(['--resume', 'sid']),
      );
    });
  });

  group('antigravityLaunchArgs', () {
    test('an unflagged launch is how the CLI already asks', () {
      // `agy` prompts before tool use unless told otherwise, so the safe mode
      // is the empty command line rather than a missing flag.
      expect(antigravityLaunchArgs(launch()), isEmpty);
    });

    test('accept-edits and bypass use the flags agy --help documents', () {
      expect(
        antigravityLaunchArgs(launch(permission: PermissionMode.acceptEdits)),
        containsAllInOrder(['--mode', 'accept-edits']),
      );
      expect(
        antigravityLaunchArgs(launch(permission: PermissionMode.bypass)),
        contains('--dangerously-skip-permissions'),
      );
    });

    test('resume names the conversation by id', () {
      expect(
        antigravityLaunchArgs(launch(resume: 'sid')),
        containsAllInOrder(['--conversation', 'sid']),
      );
    });

    test('the retired guesses are gone', () {
      // `--stdio`, `--yolo` and `--resume` were invented against a fake process
      // and are not flags this CLI has. A wrong flag does not fail loudly — it
      // makes the agent refuse to launch.
      for (final mode in PermissionMode.values) {
        final args = antigravityLaunchArgs(launch(permission: mode, resume: 's'));
        expect(args, isNot(contains('--stdio')));
        expect(args, isNot(contains('--yolo')));
        expect(args, isNot(contains('--resume')));
      }
    });
  });
}
