import 'package:test/test.dart';
import 'package:agent_cli/src/agents/domain/agent_descriptor.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_permission_support.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';
import 'package:agent_cli/src/agents/domain/permission_carry.dart';
import 'package:agent_cli/src/permissions/permission_risk.dart';

CarriedPermission _carry(PermissionRisk risk, String agentId) =>
    carryPermission(risk, AgentRegistry.builtIn.byId(agentId));

AgentDescriptor _agent(
  String id,
  String name,
  List<AgentPermissionValue> values,
) => AgentDescriptor(
  id: id,
  displayName: name,
  binaries: AgentBinaries(windows: [id], posix: [id]),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: 'test fixture',
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'test',
          defaultValueId: values.first.id,
          values: values,
        ),
      ],
    ),
  ),
);

AgentPermissionValue _value(
  String id,
  String label,
  PermissionRisk permits,
  List<String> args,
) => AgentPermissionValue(
  id: id,
  label: label,
  shortLabel: label,
  description: '$label does a thing.',
  arguments: args,
  permits: permits,
  evidence: 'test fixture',
);

/// An agent whose **only** mode is the most dangerous one.
///
/// This shape is what `permission_carry.dart` was written against, and until
/// the CLIs were actually run it was Antigravity's. No shipped agent has it any
/// more, but the rule still has to hold for one that does — and pinning the
/// test to whichever agent happened to be least understood would make it a fact
/// about our research rather than about the rule.
final _bypassOnly = _agent('bypassOnly', 'Bypass-only CLI', [
  _value('yolo', 'Bypass', PermissionRisk.bypass, ['--yolo']),
]);

void main() {
  group('a rung the target reaches travels unchanged', () {
    test('exact stays exact and says the agent was told', () {
      final carried = _carry(PermissionRisk.ask, AgentIds.claudeCode);
      expect(carried.risk, PermissionRisk.ask);
      expect(carried.fit, PermissionModeFit.exact);
      expect(carried.changed, isFalse);
      expect(carried.enforced, isTrue);
      // Claude Code's own name for the mode at that rung, not the rung's.
      expect(carried.selection, const PermissionSelection({'mode': 'manual'}));
      expect(carried.summary, contains('Claude Code is told to use it'));
    });

    test('the most permissive mode at or below the rung is the one taken', () {
      // Not the safest: an exact match must not be passed over for something
      // more careful than the user asked for.
      final carried = _carry(PermissionRisk.acceptEdits, AgentIds.claudeCode);
      expect(
        carried.selection,
        const PermissionSelection({'mode': 'acceptEdits'}),
      );
      expect(carried.fit, PermissionModeFit.exact);
    });
  });

  group('a rung the target cannot reach falls downwards, never upwards', () {
    test('a careful session handed to a bypass-only agent stays careful', () {
      // The property this rule exists for, and the sharpest case of it. A
      // "nearest available mode" rule would answer the handoff of an
      // ask-every-time session by launching the next agent with --yolo —
      // turning the user's safest choice into the most dangerous one as a
      // side effect of changing provider.
      final carried = carryPermission(PermissionRisk.ask, _bypassOnly);
      expect(carried.fit, PermissionModeFit.none);
      expect(carried.enforced, isFalse);
      // Nothing is passed. Handing over even this agent's *safest* mode would
      // still be a bypass, so the honest answer is to enforce nothing.
      expect(carried.selection, PermissionSelection.empty);
      expect(
        _bypassOnly.launch.permission.argumentsFor(carried.selection),
        isEmpty,
      );
      expect(carried.summary, contains('no mode as careful as'));
      expect(carried.summary, contains('its own default'));
      // And it must never claim the app is in control of it.
      expect(carried.summary, contains('Karmashala cannot govern it'));
    });

    test('a bypass session handed to a safer-only agent is downgraded', () {
      final safeOnly = _agent('safeOnly', 'Safe CLI', [
        _value('careful', 'Ask every time', PermissionRisk.ask, ['--careful']),
      ]);
      final carried = carryPermission(PermissionRisk.bypass, safeOnly);
      expect(carried.requested, PermissionRisk.bypass);
      expect(carried.risk, PermissionRisk.ask);
      expect(carried.changed, isTrue);
      expect(carried.fit, PermissionModeFit.approximate);
      expect(carried.summary, contains('no more permissive'));
      expect(carried.summary, contains('Ask every time'));
    });

    test('the fallback stops at the ceiling rather than reaching past it', () {
      final both = _agent('both', 'Both CLI', [
        _value('ask', 'Ask', PermissionRisk.ask, ['--ask']),
        _value('edit', 'Edit', PermissionRisk.acceptEdits, ['--edit']),
      ]);
      // `edit` is nearer to bypass and is taken, because it is still at or
      // below what was asked for.
      expect(
        carryPermission(PermissionRisk.bypass, both).selection,
        const PermissionSelection({'mode': 'edit'}),
      );
      // But a request *below* both stops at the safer one rather than climbing.
      expect(
        carryPermission(PermissionRisk.ask, both).selection,
        const PermissionSelection({'mode': 'ask'}),
      );
      // And a request below everything the agent has enforces nothing.
      expect(
        carryPermission(PermissionRisk.readOnly, both).fit,
        PermissionModeFit.none,
      );
    });
  });

  group('across the agents actually shipped', () {
    test('a plan-mode session survives onto Claude Code and Antigravity', () {
      // Both really have a plan mode, which the old three-value enum could not
      // express at all.
      expect(
        _carry(PermissionRisk.readOnly, AgentIds.claudeCode).selection,
        const PermissionSelection({'mode': 'plan'}),
      );
      expect(
        _carry(PermissionRisk.readOnly, AgentIds.antigravity).selection,
        const PermissionSelection({'mode': 'plan'}),
      );
    });

    test('Codex has nothing at "ask", and the carry says so honestly', () {
      // Declaring Codex from 0.151.0 dropped `untrusted`, which was its only
      // ask-every-time. The carry must not paper over that: it falls to the
      // read-only sandbox, which is safer, and reports the change.
      final carried = _carry(PermissionRisk.ask, AgentIds.codex);
      expect(carried.fit, PermissionModeFit.approximate);
      expect(carried.changed, isTrue);
      expect(carried.risk, PermissionRisk.readOnly);
      expect(carried.selection.valueFor('sandbox'), 'read-only');
      expect(carried.summary, contains('no more permissive'));
    });

    test('a bypass carries onto every agent that has one as its own', () {
      // Gemini CLI declares no permission vocabulary at all, so there is no
      // rung to carry onto and `carryPermission` says so rather than inventing
      // one — which the "no descriptor enforces nothing" case below asserts.
      for (final agentId in AgentRegistry.builtIn.descriptors
          .where((d) => d.launch.permission.isKnown)
          .map((d) => d.id)) {
        final carried = _carry(PermissionRisk.bypass, agentId);
        expect(carried.risk, PermissionRisk.bypass, reason: agentId);
        expect(carried.fit, PermissionModeFit.exact, reason: agentId);
      }
    });
  });

  test('an agent with no descriptor enforces nothing and says so', () {
    final carried = carryPermission(
      PermissionRisk.acceptEdits,
      null,
      targetName: 'mystery',
    );
    expect(carried.fit, PermissionModeFit.none);
    expect(carried.enforced, isFalse);
    expect(carried.selection, PermissionSelection.empty);
    expect(carried.summary, startsWith('mystery'));
  });

  test('every summary names the target agent rather than the app', () {
    for (final agentId in AgentIds.builtIn) {
      for (final risk in PermissionRisk.values) {
        final carried = _carry(risk, agentId);
        expect(
          carried.summary,
          contains(AgentRegistry.builtIn.displayNameFor(agentId)),
        );
      }
    }
  });

  group('the user picking a mode for the agent they chose', () {
    final forker = _agent('forker', 'Forker CLI', [
      _value('careful', 'Careful', PermissionRisk.ask, ['--careful']),
      _value('trust', 'Trust me', PermissionRisk.bypass, ['--trust-me']),
    ]);

    test('no pick is exactly the carry rule, and says where it came from', () {
      final resolved = resolveContinuationPermission(
        sessionRisk: PermissionRisk.ask,
        target: forker,
      );
      expect(resolved.selection, const PermissionSelection({'mode': 'careful'}));
      expect(resolved.wasChosen, isFalse);
      expect(resolved.carried.fit, PermissionModeFit.exact);
      expect(resolved.explanation, startsWith('Carried from this session.'));
      expect(resolved.explanation, contains('Forker CLI is told to use it'));
    });

    test('a pick is in the target\'s own vocabulary and is what runs', () {
      // The picker now offers only the target's own modes, so a pick needs no
      // carrying — it cannot name something the agent does not have.
      final resolved = resolveContinuationPermission(
        sessionRisk: PermissionRisk.ask,
        target: forker,
        chosen: const PermissionSelection({'mode': 'trust'}),
      );
      expect(resolved.selection, const PermissionSelection({'mode': 'trust'}));
      expect(resolved.wasChosen, isTrue);
      expect(resolved.carried.fit, PermissionModeFit.exact);
      // The user chose it, so the line does not re-explain where it came from.
      expect(resolved.explanation, isNot(contains('Carried from')));
    });

    test('the offered axes are the chosen agent\'s own, safest-first', () {
      final resolved = resolveContinuationPermission(
        sessionRisk: PermissionRisk.ask,
        target: forker,
      );
      expect(resolved.axes, hasLength(1));
      expect(
        resolved.axes.single.options.map((o) => o.id),
        ['careful', 'trust'],
      );
      // Nothing is offered that the agent cannot express, because every row is
      // one of its own modes.
      expect(
        resolved.axes.single.options.every((o) => o.isSelectable),
        isTrue,
      );
    });

    test('an agent with no declared modes offers none and enforces none', () {
      const unknown = AgentDescriptor(
        id: 'unknown',
        displayName: 'Unknown CLI',
        binaries: AgentBinaries(windows: ['u'], posix: ['u']),
        launch: AgentLaunchSpec(),
      );
      final resolved = resolveContinuationPermission(
        sessionRisk: PermissionRisk.ask,
        target: unknown,
      );
      expect(resolved.axes, isEmpty);
      expect(resolved.carried.fit, PermissionModeFit.none);
      expect(resolved.selection, PermissionSelection.empty);
    });
  });
}
