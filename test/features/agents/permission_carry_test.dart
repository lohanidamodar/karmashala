import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/permission_carry.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

CarriedPermission _carry(PermissionMode mode, String agentId) =>
    carryPermission(mode, AgentRegistry.builtIn.byId(agentId));

/// An agent whose **only** expressible mode is the most dangerous one.
///
/// This shape is what `permission_carry.dart` was written against, and until
/// the CLI was actually run it was Antigravity's — `bypass: ['--yolo']` and
/// nothing else. Interrogating `agy` 1.1.22 showed all three modes map exactly,
/// so no shipped agent has this shape any more.
///
/// The rule still has to hold for one that does, and pinning it to whichever
/// agent happened to be least understood made the test a fact about our
/// research rather than about the rule. Hence a descriptor written for it.
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
    test('a careful session handed to a bypass-only agent stays careful', () {
      // The property this rule exists for. When an agent's *only* expressible
      // mode is bypass, a "nearest available mode" rule would answer the
      // handoff of an `ask` session by launching the next agent with --yolo —
      // turning the user's safest choice into the most dangerous one as a side
      // effect of changing provider.
      final carried = carryPermission(PermissionMode.ask, _bypassOnly);
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

  group('the user picking a mode for the agent they chose', () {
    const forker = AgentDescriptor(
      id: 'forker',
      displayName: 'Forker CLI',
      binaries: AgentBinaries(windows: ['f'], posix: ['f']),
      launch: AgentLaunchSpec(
        permissionModes: {
          PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
          PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
        },
      ),
    );

    test('no pick is exactly the carry rule, and says where it came from', () {
      final resolved = resolveContinuationPermission(
        sessionMode: PermissionMode.ask,
        target: forker,
      );
      expect(resolved.mode, PermissionMode.ask);
      expect(resolved.wasChosen, isFalse);
      expect(resolved.carried.fit, PermissionModeFit.exact);
      expect(resolved.explanation, startsWith('Carried from this session.'));
      expect(resolved.explanation, contains('Forker CLI is told to use it'));
    });

    test('a pick the agent expresses is what runs', () {
      final resolved = resolveContinuationPermission(
        sessionMode: PermissionMode.ask,
        target: forker,
        chosen: PermissionMode.bypass,
      );
      expect(resolved.mode, PermissionMode.bypass);
      expect(resolved.wasChosen, isTrue);
      expect(resolved.carried.fit, PermissionModeFit.exact);
      // The user chose it, so the line does not re-explain where it came from.
      expect(resolved.explanation, isNot(contains('Carried from')));
    });

    test('a pick the agent cannot express falls downwards, never upwards', () {
      // The property the picker must not become a way around: `acceptEdits`
      // is not in Forker's vocabulary, and `bypass` — the only other mode it
      // has — is more permissive, so the answer is the safest thing it does
      // express rather than the nearest one.
      final resolved = resolveContinuationPermission(
        sessionMode: PermissionMode.bypass,
        target: forker,
        chosen: PermissionMode.acceptEdits,
      );
      expect(resolved.mode, PermissionMode.ask);
      expect(resolved.carried.changed, isTrue);
      expect(resolved.explanation, contains('no more permissive'));
    });

    test(
      'the offered modes are the chosen agent\'s, in safest-first order',
      () {
        final resolved = resolveContinuationPermission(
          sessionMode: PermissionMode.ask,
          target: forker,
        );
        expect(resolved.options.map((o) => o.mode), PermissionMode.values);
        // Loop 31 §4 option C, unchanged by there being a picker: a mode the
        // descriptor cannot express is shown and not selectable.
        expect(
          {
            for (final option in resolved.options)
              option.mode: option.isSelectable,
          },
          {
            PermissionMode.ask: true,
            PermissionMode.acceptEdits: false,
            PermissionMode.bypass: true,
          },
        );
        expect(resolved.selected.mode, PermissionMode.ask);
      },
    );

    test('an agent that can be told nothing still names its own default', () {
      final resolved = resolveContinuationPermission(
        sessionMode: PermissionMode.ask,
        target: _bypassOnly,
      );
      // Not escalated to bypass to have *something* selectable: the default
      // stays the session's mode, unenforced, and the sentence says so.
      expect(resolved.mode, PermissionMode.ask);
      expect(resolved.carried.enforced, isFalse);
      expect(resolved.explanation, contains('its own default'));
      expect(resolved.selected.isSelectable, isFalse);
    });
  });
}
