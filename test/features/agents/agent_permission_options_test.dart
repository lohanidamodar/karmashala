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
    // And `ask` is enforced by naming the mode, not by hoping the CLI's own
    // default prompts — which, on a Pro/Max/Team account, it does not.
    expect(
      registry
          .byId(AgentIds.claudeCode)!
          .launch
          .permissionArgumentsFor(PermissionMode.ask),
      ['--permission-mode', 'manual'],
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
    expect(acceptEdits.summary, contains('without asking'));

    expect(
      option(AgentIds.codex, PermissionMode.ask).fit,
      PermissionModeFit.exact,
    );
    expect(
      option(AgentIds.codex, PermissionMode.bypass).fit,
      PermissionModeFit.exact,
    );
  });

  test('Antigravity offers all three, now that the CLI has been read', () {
    // This test used to be the sharpest example of Loop 31 §4's second shape: a
    // registered agent whose descriptor omitted the *safe* modes, leaving
    // bypass as the only selectable one. That was an artefact of never having
    // run the CLI. `agy --help` documents `--mode accept-edits` and
    // `--dangerously-skip-permissions`, and prompting is what it does unflagged,
    // so all three map exactly and all three are selectable.
    for (final mode in PermissionMode.values) {
      final offered = option(AgentIds.antigravity, mode);
      expect(offered.fit, PermissionModeFit.exact, reason: mode.name);
      expect(offered.isSelectable, isTrue, reason: mode.name);
    }
  });

  test('a mode the descriptor omits is listed, unselectable, and explained', () {
    // The rule itself, which no shipped agent exercises any more. Antigravity
    // was standing in for it; pinning it to whichever agent happened to be
    // least understood made the test a fact about our research rather than
    // about the rule.
    const bypassOnly = AgentDescriptor(
      id: 'bypassOnly',
      displayName: 'Bypass-only CLI',
      binaries: AgentBinaries(windows: ['b'], posix: ['b']),
      launch: AgentLaunchSpec(
        permissionModes: {
          PermissionMode.bypass: PermissionModeMapping.exact(['--yolo']),
        },
      ),
    );
    final options = permissionOptionsFor(bypassOnly);
    final ask = options.firstWhere((o) => o.mode == PermissionMode.ask);

    expect(ask.fit, PermissionModeFit.none);
    expect(ask.isSelectable, isFalse);
    expect(ask.fitLabel, 'not enforced');
    // The sentence names the agent, so the user reads it as a property of that
    // CLI rather than as Chitragupta being broken.
    expect(ask.summary, contains('Bypass-only CLI'));
    expect(ask.summary, contains('own default applies'));
    // Listed but not choosable — hiding it would leave the user wondering where
    // the safe option went.
    expect(options.map((o) => o.mode), PermissionMode.values);
    expect(options.where((o) => o.isSelectable).map((o) => o.mode), [
      PermissionMode.bypass,
    ]);
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
