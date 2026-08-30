import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/permission_carry.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

CarriedPermission _carry(PermissionMode mode, String agentId) =>
    carryPermission(mode, AgentRegistry.builtIn.byId(agentId));

void main() {
  group('a mode the target understands travels unchanged', () {
    test('exact stays exact and says the agent was told', () {
      final carried = _carry(PermissionMode.ask, AgentIds.claudeCode);
      expect(carried.mode, PermissionMode.ask);
      expect(carried.fit, PermissionModeFit.exact);
      expect(carried.changed, isFalse);
      expect(carried.enforced, isTrue);
      expect(carried.summary, contains('Claude Code is told to use it'));
    });

    test('approximate carries the descriptor\'s own words', () {
      final carried = _carry(PermissionMode.acceptEdits, AgentIds.codex);
      expect(carried.mode, PermissionMode.acceptEdits);
      expect(carried.fit, PermissionModeFit.approximate);
      expect(carried.changed, isFalse);
      expect(carried.summary, startsWith('Accept edits — Approximate'));
      expect(carried.summary, contains('Codex has no accept-edits mode'));
    });
  });

  group('a mode the target cannot express falls downwards, never upwards', () {
    test('a careful session handed to Antigravity does not become --yolo', () {
      // The property this rule exists for. Antigravity's *only* expressible
      // mode is bypass, so a "nearest available mode" rule would answer the
      // handoff of an `ask` session by launching the next agent with --yolo —
      // turning the user's safest choice into the most dangerous one as a side
      // effect of changing provider.
      final carried = _carry(PermissionMode.ask, AgentIds.antigravity);
      expect(carried.mode, PermissionMode.ask);
      expect(carried.fit, PermissionModeFit.none);
      expect(carried.enforced, isFalse);
      expect(carried.changed, isFalse);
      expect(carried.summary, contains('takes no flag'));
      expect(carried.summary, contains('its own default'));
      // And it must never claim the app is in control of it.
      expect(carried.summary, contains('Chitragupta cannot govern it'));
    });

    test('a bypass session handed to a safer-only agent is downgraded', () {
      const safeOnly = AgentDescriptor(
        id: 'safeOnly',
        displayName: 'Safe CLI',
        binaries: AgentBinaries(windows: ['s'], posix: ['s']),
        launch: AgentLaunchSpec(
          permissionModes: {
            PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
          },
        ),
      );
      final carried = carryPermission(PermissionMode.bypass, safeOnly);
      expect(carried.requested, PermissionMode.bypass);
      expect(carried.mode, PermissionMode.ask);
      expect(carried.changed, isTrue);
      expect(carried.fit, PermissionModeFit.exact);
      expect(carried.summary, contains('no more permissive'));
      expect(carried.summary, contains('Ask every time'));
    });

    test('the fallback takes the safest option, not the closest one', () {
      const both = AgentDescriptor(
        id: 'both',
        displayName: 'Both CLI',
        binaries: AgentBinaries(windows: ['b'], posix: ['b']),
        launch: AgentLaunchSpec(
          permissionModes: {
            PermissionMode.ask: PermissionModeMapping.exact(['--ask']),
            PermissionMode.acceptEdits: PermissionModeMapping.exact(['--edit']),
          },
        ),
      );
      final carried = carryPermission(PermissionMode.bypass, both);
      // `acceptEdits` is nearer to bypass; `ask` is safer. Safety wins, because
      // the user is choosing an agent here, not loosening a policy.
      expect(carried.mode, PermissionMode.ask);
    });
  });

  test('an agent with no descriptor enforces nothing and says so', () {
    final carried = carryPermission(
      PermissionMode.acceptEdits,
      null,
      targetName: 'mystery',
    );
    expect(carried.fit, PermissionModeFit.none);
    expect(carried.enforced, isFalse);
    expect(carried.summary, startsWith('mystery takes no flag'));
  });

  test('every summary names the target agent rather than the app', () {
    for (final agentId in AgentIds.builtIn) {
      for (final mode in PermissionMode.values) {
        final carried = _carry(mode, agentId);
        expect(
          carried.summary,
          contains(AgentRegistry.builtIn.displayNameFor(agentId)),
        );
      }
    }
  });
}
