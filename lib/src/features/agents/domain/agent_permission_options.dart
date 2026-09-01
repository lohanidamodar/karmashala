import '../../settings/domain/permission_mode.dart';
import 'agent_descriptor.dart';

/// One row of a permission control: a mode, how faithfully it reaches this
/// agent, and the words for saying so.
///
/// Pulled out of the widget because the *wording* is the feature. A control that
/// offers "Accept edits" for Codex without saying that Codex has no such mode is
/// the silent no-op Loop 31 §4 described, just with a nicer font.
class AgentPermissionOption {
  const AgentPermissionOption({
    required this.mode,
    required this.fit,
    required this.agentName,
    this.note,
  });

  final PermissionMode mode;
  final PermissionModeFit fit;

  /// The agent's display name, so every sentence below names who is or is not
  /// honouring the choice rather than blaming "the app".
  final String agentName;

  /// The descriptor's own words about this mode, when it has any.
  final String? note;

  /// Whether the user may choose this mode.
  ///
  /// This is Loop 31's option C: a mode the descriptor cannot express is not
  /// selectable, so the request that would have been silently dropped cannot be
  /// made. It is still *shown*, disabled and explained — hiding it would leave
  /// the user wondering where the safe option went, which is a different kind of
  /// silence.
  bool get isSelectable => fit != PermissionModeFit.none;

  /// One sentence about what picking this mode actually does to this agent.
  String get summary => switch (fit) {
    PermissionModeFit.exact =>
      note ?? '$agentName supports this mode and is told to use it.',
    PermissionModeFit.approximate => 'Approximate. ${note ?? ''}'.trim(),
    PermissionModeFit.none =>
      '$agentName takes no flag for this, so its own default applies and '
          'Karmashala cannot enforce the choice.',
  };

  /// A two-or-three word badge for the same fact, for the chip and the menu row.
  String get fitLabel => switch (fit) {
    PermissionModeFit.exact => 'exact',
    PermissionModeFit.approximate => 'approximate',
    PermissionModeFit.none => 'not enforced',
  };
}

/// Every [PermissionMode] paired with how it maps onto [descriptor], in the
/// enum's own order (safest first).
///
/// A null [descriptor] — the unknown-agent shape from Loop 31 §4 — yields
/// [PermissionModeFit.none] for every mode, through exactly the same code as a
/// known agent that omits one. The two shapes were separate bugs and get one
/// answer.
List<AgentPermissionOption> permissionOptionsFor(
  AgentDescriptor? descriptor, {
  String? agentName,
}) {
  final name = agentName ?? descriptor?.displayName ?? 'This agent';
  return [
    for (final mode in PermissionMode.values)
      AgentPermissionOption(
        mode: mode,
        fit:
            descriptor?.launch.permissionFitFor(mode) ?? PermissionModeFit.none,
        note: descriptor?.launch.permissionNoteFor(mode),
        agentName: name,
      ),
  ];
}
