import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';

import '../../settings/domain/settings.dart';

/// **One agent's installations on one machine**, its terminal and chat forms
/// together: what New Session shows as one card.
class FoldedInstallations {
  const FoldedInstallations({
    required this.forms,
    required this.environmentId,
    required this.installations,
  });

  final AgentForms forms;
  final String environmentId;

  /// Terminal form first, each form in the order it was given.
  final List<AgentInstallation> installations;

  AgentInstallation get first => installations.first;

  /// A stable key: the id of [first].
  String get key => first.id;

  AgentInstallation? installationFor(AgentRunForm form) {
    final id = forms.idFor(form);
    return installations.where((i) => i.agentId == id).firstOrNull;
  }

  /// Whether both forms are installed here, so the card offers the choice.
  bool get offersChoice =>
      installationFor(AgentRunForm.terminal) != null &&
      installationFor(AgentRunForm.chat) != null;

  /// The installation of [form] here, else [first].
  AgentInstallation preferring(AgentRunForm form) =>
      installationFor(form) ?? first;

  bool contains(AgentInstallation? installation) =>
      installation != null && installations.any((i) => i.id == installation.id);
}

/// [installations] grouped by folded agent and machine, in the order each
/// group's first installation appears.
List<FoldedInstallations> foldInstallations(
  AgentRegistry registry,
  Iterable<AgentInstallation> installations,
) {
  final groups = <(String, String), List<AgentInstallation>>{};
  for (final install in installations) {
    final key = (registry.foldedIdOf(install.agentId), install.environmentId);
    (groups[key] ??= []).add(install);
  }
  // An agent's machines side by side, agents in the order they came.
  final agents = <String>{
    for (final (agentId, _) in groups.keys) agentId,
  }.toList();
  final ordered = groups.entries.toList()
    ..sort((a, b) => agents.indexOf(a.key.$1) - agents.indexOf(b.key.$1));
  return [
    for (final MapEntry(key: (agentId, environmentId), value: installs)
        in ordered)
      FoldedInstallations(
        forms: registry.formsOf(agentId),
        environmentId: environmentId,
        installations: [
          for (final form in AgentRunForm.values)
            ...installs.where((i) => registry.formOf(i.agentId) == form),
        ],
      ),
  ];
}

/// [installation] moved to the form chosen for its agent, when one was chosen
/// and that form is among [installations] on the same machine; else as given.
AgentInstallation inChosenForm(
  AgentInstallation installation,
  Iterable<AgentInstallation> installations,
  AgentRegistry registry,
  Settings settings,
) {
  final forms = registry.formsOf(installation.agentId);
  final chosen = settings.chosenRunFormFor(forms.agentId);
  final id = chosen == null ? null : forms.idFor(chosen);
  if (id == null || id == installation.agentId) return installation;
  return installations
          .where(
            (i) =>
                i.agentId == id &&
                i.environmentId == installation.environmentId,
          )
          .firstOrNull ??
      installation;
}
