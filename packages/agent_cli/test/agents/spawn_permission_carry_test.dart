import 'package:test/test.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_permission_support.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:agent_cli/src/agents/domain/permission_carry.dart';
import 'package:agent_cli/src/permissions/permission_risk.dart';

SpawnCarry _spawn(
  PermissionRisk requested,
  PermissionRisk callerRisk, [
  String agentId = AgentIds.claudeCode,
]) => carrySpawnPermission(
  requested: requested,
  callerRisk: callerRisk,
  target: AgentRegistry.builtIn.byId(agentId),
);

void main() {
  group('a session an agent starts holds no more than it may', () {
    test('a bypass caller cannot hand a child bypass', () {
      final carry = _spawn(PermissionRisk.bypass, PermissionRisk.bypass);
      expect(carry.wasCapped, isTrue);
      expect(carry.boundByCaller, isFalse);
      expect(carry.carried.risk, PermissionRisk.autoRun);
      expect(carry.selection, const PermissionSelection({'mode': 'auto'}));
      expect(carry.refusal, contains('capped at automatic'));
    });

    test('a plan-mode caller cannot start a child that writes', () {
      final carry = _spawn(PermissionRisk.acceptEdits, PermissionRisk.readOnly);
      expect(carry.wasCapped, isTrue);
      expect(carry.boundByCaller, isTrue);
      expect(carry.carried.risk, PermissionRisk.readOnly);
      expect(carry.refusal, contains('runs at read-only'));
      expect(carry.refusal, contains('"readOnly"'));
    });

    test('asking for no more than the caller holds is not capped', () {
      final carry = _spawn(PermissionRisk.acceptEdits, PermissionRisk.bypass);
      expect(carry.wasCapped, isFalse);
      expect(carry.carried.risk, PermissionRisk.acceptEdits);
    });

    test(
      'the cap is applied before the carry, so Codex falls to its sandbox',
      () {
        final carry = _spawn(
          PermissionRisk.bypass,
          PermissionRisk.bypass,
          AgentIds.codex,
        );
        expect(carry.carried.risk, PermissionRisk.acceptEdits);
        expect(carry.selection.values['sandbox'], 'workspace-write');
      },
    );
  });
}
