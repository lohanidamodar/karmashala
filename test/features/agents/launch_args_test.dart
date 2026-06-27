import 'package:chitragupta/src/features/agents/data/antigravity_adapter.dart';
import 'package:chitragupta/src/features/agents/data/claude_code_adapter.dart';
import 'package:chitragupta/src/features/agents/data/codex_adapter.dart';
import 'package:chitragupta/src/features/agents/domain/agent_adapter.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
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
    test('ask adds no permission flag', () {
      expect(claudeLaunchArgs(launch()), isNot(contains('--permission-mode')));
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
    test('adds --yolo only on bypass; resume adds --resume', () {
      expect(antigravityLaunchArgs(launch()), isNot(contains('--yolo')));
      expect(
        antigravityLaunchArgs(launch(permission: PermissionMode.bypass)),
        contains('--yolo'),
      );
      expect(
        antigravityLaunchArgs(launch(resume: 'sid')),
        containsAllInOrder(['--resume', 'sid']),
      );
    });
  });
}
