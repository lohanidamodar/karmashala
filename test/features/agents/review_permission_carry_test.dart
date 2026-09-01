import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/permission_carry.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

ReviewCarry _review(PermissionMode sessionMode, String agentId) =>
    carryReviewPermission(
      sessionMode: sessionMode,
      target: AgentRegistry.builtIn.byId(agentId),
    );

/// An agent whose **only** expressible mode is the most dangerous one — the
/// shape `permission_carry.dart` was written against.
const _bypassOnly = AgentDescriptor(
  id: 'bypassOnly',
  displayName: 'Bypass-only CLI',
  binaries: AgentBinaries(windows: ['b'], posix: ['b']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.bypass: PermissionModeMapping.exact(['--yolo']),
    },
  ),
);

void main() {
  group('a review carry is a cap, never an escape hatch', () {
    test('the most autonomous session still gets a careful reviewer', () {
      final carry = _review(PermissionMode.bypass, AgentIds.claudeCode);
      expect(carry.mode, PermissionMode.ask);
      expect(carry.wasCapped, isTrue);
      expect(carry.summary, contains('Bypass (full autonomy)'));
      expect(carry.summary, contains('Claude Code'));
    });

    test('accept-edits is capped too, because editing is writing', () {
      final carry = _review(PermissionMode.acceptEdits, AgentIds.codex);
      expect(carry.mode, PermissionMode.ask);
      expect(carry.wasCapped, isTrue);
    });

    test('a session already at the ceiling is carried unchanged', () {
      final carry = _review(PermissionMode.ask, AgentIds.claudeCode);
      expect(carry.mode, PermissionMode.ask);
      expect(carry.wasCapped, isFalse);
      expect(carry.carried.fit, PermissionModeFit.exact);
    });

    test('no session mode can produce a reviewer above the ceiling', () {
      for (final mode in PermissionMode.values) {
        for (final agentId in AgentIds.builtIn) {
          final carry = _review(mode, agentId);
          expect(
            PermissionMode.values.indexOf(carry.mode),
            lessThanOrEqualTo(
              PermissionMode.values.indexOf(reviewPermissionCeiling),
            ),
            reason: '$agentId reviewing a $mode session',
          );
        }
      }
    });
  });

  group('the cap still goes through the downwards-only carry', () {
    test('an agent that cannot express the ceiling is not raised to bypass', () {
      final carry = carryReviewPermission(
        sessionMode: PermissionMode.bypass,
        target: _bypassOnly,
      );
      expect(carry.mode, PermissionMode.ask);
      expect(carry.carried.fit, PermissionModeFit.none);
      expect(carry.summary, contains('Bypass-only CLI'));
      expect(carry.summary, contains('cannot govern it'));
    });

    test('an unknown agent is named and not enforced', () {
      final carry = carryReviewPermission(
        sessionMode: PermissionMode.ask,
        target: null,
        targetName: 'Mystery CLI',
      );
      expect(carry.mode, PermissionMode.ask);
      expect(carry.carried.enforced, isFalse);
      expect(carry.summary, contains('Mystery CLI'));
    });
  });

  test('the summary says why a reviewer is capped, not just that it is', () {
    final carry = _review(PermissionMode.bypass, AgentIds.claudeCode);
    expect(carry.summary, contains('review'));
    expect(carry.summary.toLowerCase(), contains('write'));
  });
}
