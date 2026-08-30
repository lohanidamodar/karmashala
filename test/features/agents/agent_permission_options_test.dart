import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_permission_options.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the permission control is allowed to offer, per agent.
///
/// Loop 31 §4 recommended option C — "offer only the modes the descriptor can
/// express" — and deferred it until a per-session control existed. These are the
/// assertions that say it landed.
void main() {
  const registry = AgentRegistry.builtIn;
  List<AgentPermissionOption> optionsFor(String id) =>
      permissionOptionsFor(registry.byId(id));
  AgentPermissionOption option(String id, PermissionMode mode) =>
      optionsFor(id).firstWhere((o) => o.mode == mode);

  test('every mode is listed, in the enum order, for every agent', () {
    // Listed, not necessarily selectable. Hiding a mode entirely would leave
    // the user wondering where the safe option went, which is its own silence.
    for (final descriptor in registry.descriptors) {
      expect(
        permissionOptionsFor(descriptor).map((o) => o.mode),
        PermissionMode.values,
        reason: descriptor.id,
      );
    }
  });

  test('an unknown agent can express nothing', () {
    // The first of Loop 31's two shapes: `AgentRegistry.byId` returns null. It
    // must not silently offer `ask` — for an unregistered agent `ask` adds no
    // flag at all, so the agent's own unverified default applies.
    final options = permissionOptionsFor(null);
    expect(options.every((o) => o.fit == PermissionModeFit.none), isTrue);
    expect(options.every((o) => o.isSelectable), isFalse);
    expect(options.first.summary, contains('cannot enforce'));
  });

  test('Claude Code expresses all three exactly', () {
    for (final mode in PermissionMode.values) {
      expect(
        option(AgentIds.claudeCode, mode).fit,
        PermissionModeFit.exact,
        reason: mode.name,
      );
      expect(option(AgentIds.claudeCode, mode).isSelectable, isTrue);
    }
    // `ask` is exact with no flag, and says so rather than leaving the user to
    // wonder why the safest mode adds nothing to the command line.
    expect(
      option(AgentIds.claudeCode, PermissionMode.ask).summary,
      contains('by default'),
    );
  });

  test('Codex accept-edits is offered, and admits it is an approximation', () {
    final acceptEdits = option(AgentIds.codex, PermissionMode.acceptEdits);
    expect(acceptEdits.fit, PermissionModeFit.approximate);
    // Selectable — it is the nearest thing Codex has and refusing it would
    // block a real choice — but it must never read as plain "Accept edits".
    expect(acceptEdits.isSelectable, isTrue);
    expect(acceptEdits.fitLabel, 'approximate');
    expect(acceptEdits.summary, startsWith('Approximate.'));
    expect(acceptEdits.summary, contains('on-failure'));

    expect(
      option(AgentIds.codex, PermissionMode.ask).fit,
      PermissionModeFit.exact,
    );
    expect(
      option(AgentIds.codex, PermissionMode.bypass).fit,
      PermissionModeFit.exact,
    );
  });

  test('Antigravity offers only what it can be told', () {
    // The second of Loop 31's two shapes, and the sharper one: a *registered*
    // agent whose descriptor omits a mode. The mode being dropped here is the
    // safe one, so this is the case where a silent no-op is worst.
    final ask = option(AgentIds.antigravity, PermissionMode.ask);
    expect(ask.fit, PermissionModeFit.none);
    expect(ask.isSelectable, isFalse);
    expect(ask.fitLabel, 'not enforced');
    // The sentence names the agent, so the user reads it as a property of
    // Antigravity rather than as Chitragupta being broken.
    expect(ask.summary, contains('Antigravity'));
    expect(ask.summary, contains('own default applies'));

    expect(
      option(AgentIds.antigravity, PermissionMode.acceptEdits).isSelectable,
      isFalse,
    );
    expect(
      option(AgentIds.antigravity, PermissionMode.bypass).isSelectable,
      isTrue,
    );

    // Which leaves bypass as the only selectable mode. That is an uncomfortable
    // control and an honest one: Chitragupta genuinely cannot govern this agent,
    // and the old data claimed it could.
    expect(
      optionsFor(
        AgentIds.antigravity,
      ).where((o) => o.isSelectable).map((o) => o.mode),
      [PermissionMode.bypass],
    );
  });

  test('selectable is exactly what the descriptor declares', () {
    // The control and the launcher must not be able to disagree about which
    // modes exist: both sides read the same declared map.
    for (final descriptor in registry.descriptors) {
      expect(
        permissionOptionsFor(
          descriptor,
        ).where((o) => o.isSelectable).map((o) => o.mode).toList(),
        descriptor.launch.expressiblePermissionModes,
        reason: descriptor.id,
      );
    }
  });
}
