import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/permission_carry.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';

ReviewCarry _review(PermissionRisk sessionRisk, String agentId) =>
    carryReviewPermission(
      sessionRisk: sessionRisk,
      target: AgentRegistry.builtIn.byId(agentId),
    );

/// An agent whose **only** mode is the most dangerous one — the shape
/// `permission_carry.dart` was written against.
const _bypassOnly = AgentDescriptor(
  id: 'bypassOnly',
  displayName: 'Bypass-only CLI',
  binaries: AgentBinaries(windows: ['b'], posix: ['b']),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: 'test fixture',
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'test',
          defaultValueId: 'yolo',
          values: [
            AgentPermissionValue(
              id: 'yolo',
              label: 'Bypass',
              shortLabel: 'Bypass',
              description: 'Everything, without asking.',
              arguments: ['--yolo'],
              permits: PermissionRisk.bypass,
              isDangerous: true,
              evidence: 'test fixture',
            ),
          ],
        ),
      ],
    ),
  ),
);

void main() {
  group('a review carry is a cap, never an escape hatch', () {
    test('the most autonomous session still gets a careful reviewer', () {
      final carry = _review(PermissionRisk.bypass, AgentIds.claudeCode);
      expect(carry.carried.risk, PermissionRisk.ask);
      expect(carry.selection, const PermissionSelection({'mode': 'manual'}));
      expect(carry.wasCapped, isTrue);
      expect(carry.summary, contains('bypass (full autonomy)'));
      expect(carry.summary, contains('Claude Code'));
    });

    test('accept-edits is capped too, because editing is writing', () {
      final carry = _review(PermissionRisk.acceptEdits, AgentIds.codex);
      expect(carry.wasCapped, isTrue);
      // Codex has nothing at the `ask` rung since `untrusted` was dropped, so
      // the cap lands on the safest thing it does have rather than pretending.
      expect(carry.carried.risk!.isAtMost(reviewPermissionCeiling), isTrue);
      expect(carry.selection.valueFor('sandbox'), 'read-only');
    });

    test('a session already at the ceiling is carried unchanged', () {
      final carry = _review(PermissionRisk.ask, AgentIds.claudeCode);
      expect(carry.carried.risk, PermissionRisk.ask);
      expect(carry.wasCapped, isFalse);
      expect(carry.carried.fit, PermissionModeFit.exact);
    });

    test('a session already below the ceiling is not raised to it', () {
      // A plan-mode session reviewed by Claude Code stays in plan mode: the
      // ceiling is a maximum, not a target.
      final carry = _review(PermissionRisk.readOnly, AgentIds.claudeCode);
      expect(carry.carried.risk, PermissionRisk.readOnly);
      expect(carry.wasCapped, isFalse);
      expect(carry.selection, const PermissionSelection({'mode': 'plan'}));
    });

    test('no session rung can produce a reviewer above the ceiling', () {
      for (final risk in PermissionRisk.values) {
        for (final agentId in AgentIds.builtIn) {
          final carry = _review(risk, agentId);
          final resolved = carry.carried.risk;
          if (resolved == null) continue; // enforced nothing; nothing to cap
          expect(
            resolved.isAtMost(reviewPermissionCeiling),
            isTrue,
            reason: '$agentId reviewing a ${risk.name} session',
          );
        }
      }
    });
  });

  group('the cap still goes through the downwards-only carry', () {
    test('an agent that cannot express the ceiling is not raised to bypass', () {
      final carry = carryReviewPermission(
        sessionRisk: PermissionRisk.bypass,
        target: _bypassOnly,
      );
      expect(carry.carried.fit, PermissionModeFit.none);
      // Nothing is passed rather than this agent's only mode, which is a
      // bypass — a reviewer that could write is not reviewing the change.
      expect(carry.selection, PermissionSelection.empty);
      expect(
        _bypassOnly.launch.permission.argumentsFor(carry.selection),
        isEmpty,
      );
      expect(carry.summary, contains('Bypass-only CLI'));
      expect(carry.summary, contains('cannot govern it'));
    });

    test('an unknown agent is named and not enforced', () {
      final carry = carryReviewPermission(
        sessionRisk: PermissionRisk.ask,
        target: null,
        targetName: 'Mystery CLI',
      );
      expect(carry.carried.enforced, isFalse);
      expect(carry.selection, PermissionSelection.empty);
      expect(carry.summary, contains('Mystery CLI'));
    });
  });

  test('the summary says why a reviewer is capped, not just that it is', () {
    final carry = _review(PermissionRisk.bypass, AgentIds.claudeCode);
    expect(carry.summary, contains('review'));
    expect(carry.summary.toLowerCase(), contains('write'));
  });
}
