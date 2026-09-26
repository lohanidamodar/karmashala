import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala_remote/remote.dart';

/// One installed agent as a real choice for the phone, whoever serves it. A
/// mode the descriptor cannot express arrives `selectable: false` with the
/// agent's own explanation. [defaultMode] is what a new session would start
/// under here: the desktop's setting, or — on a host with no settings — the
/// agent's declared default.
RemoteAgentOption remoteAgentOptionFor(
  AgentInstallation installation,
  AgentDescriptor? descriptor, {
  required String defaultMode,
}) {
  final name = descriptor?.displayName ?? installation.agentId;
  return RemoteAgentOption(
    installationId: installation.id,
    agentId: installation.agentId,
    name: name,
    version: installation.version,
    defaultMode: defaultMode,
    acceptsOpeningMessage: descriptor?.launch.acceptsPromptArgument ?? false,
    // The agent's real selections, flattened: the wire carries an opaque mode
    // id with the host's words beside it, so an older phone shows them all.
    permissionModes: () {
      final support = descriptor?.launch.permission;
      if (support == null || !support.isKnown) {
        return [
          RemotePermissionOption(
            mode: '',
            label: 'Not established',
            summary: unknownAgentReason(name),
            selectable: false,
          ),
        ];
      }
      return [
        for (final selection in support.selections())
          RemotePermissionOption(
            mode: selection.canonical,
            // Minted here, so the phone shows the same pairing the desktop does
            // without knowing the rungs exist.
            label: describeSelectionFamiliar(support, selection),
            summary:
                describeSelectionDetail(support, selection) ??
                describeSelectionFamiliar(support, selection),
            selectable: true,
            dangerous: support.isDangerous(selection),
          ),
      ];
    }(),
  );
}

/// Every permission selection a phone may put a running session on: each
/// combination of the axes, as the agent itself resolves it, less any that
/// removes every prompt — that one needs the desktop's own confirmation.
List<RemoteChoice> safePermissionChoices(AgentPermissionSupport modes) {
  if (!modes.isKnown) return const [];
  var combos = <Map<String, String>>[{}];
  for (final axis in modes.axes) {
    combos = [
      for (final partial in combos)
        for (final value in axis.values) {...partial, axis.id: value.id},
    ];
  }
  final seen = <String>{};
  return [
    for (final combo in combos)
      if (modes.normalise(PermissionSelection(combo)) case final selection
          when !modes.isDangerous(selection) && seen.add(selection.canonical))
        RemoteChoice(
          id: selection.canonical,
          label: describeSelection(modes, selection),
          summary: describeSelectionDetail(modes, selection) ?? '',
        ),
  ];
}

/// The permission selection [requested] names among [descriptor]'s, or the
/// refusal a phone is told: enforced, not merely offered — `workspace.list`
/// already said which modes exist.
({PermissionSelection? selection, String? refusal}) permissionChoice(
  AgentDescriptor? descriptor,
  String agentName,
  String requested,
) {
  final support = descriptor?.launch.permission;
  if (support == null || !support.isKnown) {
    return (selection: null, refusal: unknownAgentReason(agentName));
  }
  final mode = support
      .selections()
      .where((s) => s.canonical == requested)
      .firstOrNull;
  if (mode == null) {
    return (
      selection: null,
      refusal: '$agentName has no permission mode called "$requested"',
    );
  }
  return (selection: mode, refusal: null);
}
