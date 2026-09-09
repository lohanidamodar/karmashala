import 'package:test/test.dart';
import 'package:agent_cli/src/agents/domain/agent_descriptor.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/domain/agent_permission_options.dart';
import 'package:agent_cli/src/agents/domain/agent_permission_support.dart';
import 'package:agent_cli/src/agents/domain/agent_registry.dart';

/// What a permission control is allowed to offer, per agent.
///
/// The old rule — "offer only the modes the descriptor can express" — is now
/// true by construction: every row *is* one of the agent's own modes, so there
/// is nothing left to filter. What these assertions protect is the property
/// that survived it: **a row the user cannot pick is shown, disabled, and says
/// why**, and an agent nobody has established says that rather than showing an
/// empty menu.
void main() {
  const registry = AgentRegistry.builtIn;

  test('every agent that declares modes offers its own axes, safest-first', () {
    // An agent whose modes nobody has established offers nothing and says so —
    // asserted on its own below, and true of Gemini CLI by design.
    for (final descriptor in registry.descriptors.where(
      (d) => d.launch.permission.isKnown,
    )) {
      final axes = permissionAxisOptionsFor(descriptor);
      expect(axes, isNotEmpty, reason: descriptor.id);
      for (final axis in axes) {
        final declared = descriptor.launch.permission
            .axisFor(axis.id)!
            .values
            .map((v) => v.id);
        // The control and the launcher must not be able to disagree about
        // which modes exist: both read the same declared axes.
        expect(axis.options.map((o) => o.id), declared, reason: axis.id);
      }
    }
  });

  test('Claude Code offers six modes in one axis', () {
    final axes = permissionAxisOptionsFor(registry.byId(AgentIds.claudeCode));
    expect(axes, hasLength(1));
    expect(axes.single.options.map((o) => o.id), [
      'plan',
      'dontAsk',
      'manual',
      'acceptEdits',
      'auto',
      'bypassPermissions',
    ]);
    // All selectable: nothing here is a mode the CLI lacks.
    expect(axes.single.options.every((o) => o.isSelectable), isTrue);
    // And the default is named rather than left to the CLI, which on a
    // Pro/Max/Team account starts unflagged sessions in `auto`.
    expect(axes.single.selectedId, 'manual');
  });

  test('Codex offers two axes, not one flattened list', () {
    final axes = permissionAxisOptionsFor(registry.byId(AgentIds.codex));
    expect(axes.map((a) => a.id), ['sandbox', 'approval']);
    expect(axes[0].options.map((o) => o.id), [
      'read-only',
      'workspace-write',
      'danger-full-access',
      'bypass-all',
    ]);
    expect(axes[1].options.map((o) => o.id), ['on-request', 'never']);
  });

  test('Antigravity offers plan mode, which the old model could not', () {
    final axes = permissionAxisOptionsFor(registry.byId(AgentIds.antigravity));
    expect(axes.single.options.map((o) => o.id), [
      'plan',
      'prompt',
      'accept-edits',
      'skip-permissions',
    ]);
  });

  test('a superseded axis is shown, disabled, and says what replaced it', () {
    // The live case of the disabled-with-a-reason rule. Codex's bypass flag
    // replaces the approval policy outright, so every row on that axis is
    // greyed — shown rather than hidden, because a picker that silently
    // emptied itself would be a different kind of silence.
    final axes = permissionAxisOptionsFor(
      registry.byId(AgentIds.codex),
      selection: const PermissionSelection({
        'sandbox': 'bypass-all',
        'approval': 'on-request',
      }),
    );
    final approval = axes.firstWhere((a) => a.id == 'approval');
    expect(approval.options.every((o) => o.isSelectable), isFalse);
    for (final option in approval.options) {
      expect(option.summary, contains('Bypass approvals and sandbox'));
      expect(option.summary, contains('nothing set here is passed'));
    }
    // The sandbox axis itself stays selectable — it is the one that decided.
    final sandbox = axes.firstWhere((a) => a.id == 'sandbox');
    expect(sandbox.options.every((o) => o.isSelectable), isTrue);
  });

  test('an agent nobody has established offers nothing, and says why', () {
    // Two shapes, one answer: an agent missing from the registry, and one
    // present but with no declared modes. Both draw the single explained row
    // rather than a menu of guesses.
    const unestablished = AgentDescriptor(
      id: 'mystery',
      displayName: 'Mystery CLI',
      binaries: AgentBinaries(windows: ['m'], posix: ['m']),
      launch: AgentLaunchSpec(),
    );
    expect(permissionAxisOptionsFor(null), isEmpty);
    expect(permissionAxisOptionsFor(unestablished), isEmpty);

    final reason = unknownAgentReason('Mystery CLI');
    // The sentence names the agent, so the user reads it as a property of that
    // CLI rather than as Karmashala being broken.
    expect(reason, contains('Mystery CLI'));
    expect(reason, contains('its own default'));
    expect(reason, contains('nothing here can govern it'));
  });

  group('what a control calls a selection', () {
    test('one axis is the mode name; two are joined', () {
      final claude = registry.byId(AgentIds.claudeCode)!.launch.permission;
      expect(
        describeSelection(claude, const PermissionSelection({'mode': 'plan'})),
        'Plan mode',
      );
      final codex = registry.byId(AgentIds.codex)!.launch.permission;
      expect(
        describeSelection(
          codex,
          const PermissionSelection({
            'sandbox': 'read-only',
            'approval': 'never',
          }),
        ),
        'Read-only · Never ask',
      );
      // The chip's shorter form, for a control with a third of a window.
      expect(
        describeSelectionShort(
          codex,
          const PermissionSelection({
            'sandbox': 'read-only',
            'approval': 'never',
          }),
        ),
        'Read-only · Never ask',
      );
    });

    test('a superseded axis is left out of the name and the detail', () {
      final codex = registry.byId(AgentIds.codex)!.launch.permission;
      const bypass = PermissionSelection({
        'sandbox': 'bypass-all',
        'approval': 'never',
      });
      expect(describeSelection(codex, bypass), 'Bypass approvals and sandbox');
      expect(describeSelectionDetail(codex, bypass), isNot(contains('Never')));
    });
  });
}
