import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';

import '../../environments/data/environments_data.dart';
import '../data/agents_data.dart';

/// What to call each of [installations] where they are listed together: the
/// agent's name, and — only where two installations of one agent sit side by
/// side — where each lives ("Claude Code · WSL"), or, in one environment, its
/// folder.
Map<String, String> installationLabels(
  Iterable<AgentInstallation> installations, {
  required AgentRegistry registry,
  required String? Function(String environmentId) environmentName,
}) {
  final all = installations.toList();
  final byAgent = <String, List<AgentInstallation>>{};
  for (final installation in all) {
    byAgent.putIfAbsent(installation.agentId, () => []).add(installation);
  }
  return {
    for (final installation in all)
      installation.id: _label(
        installation,
        byAgent[installation.agentId]!,
        registry.displayNameFor(installation.agentId),
        environmentName,
      ),
  };
}

String _label(
  AgentInstallation installation,
  List<AgentInstallation> siblings,
  String name,
  String? Function(String environmentId) environmentName,
) {
  if (siblings.length < 2) return name;
  final environments = {for (final s in siblings) s.environmentId};
  if (environments.length == siblings.length) {
    final where = environmentName(installation.environmentId);
    if (where != null && where.isNotEmpty) return '$name · $where';
  }
  return '$name · ${_folderOf(installation.executable.path)}';
}

/// The executable's folder, its last two parts: enough to tell two installs
/// on one machine apart without a whole path in a menu row.
String _folderOf(String path) {
  final parts = path
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length < 2) return path;
  final folder = parts.sublist(0, parts.length - 1);
  return folder.length <= 2
      ? folder.join('/')
      : '…/${folder.sublist(folder.length - 2).join('/')}';
}

/// [installationLabels] over the installations named by [ids], read from this
/// client's rows.
Map<String, String> installationLabelsOf(
  Iterable<String> ids, {
  required AgentInstallationsData rows,
  required EnvironmentsData environments,
  required AgentRegistry registry,
}) => installationLabels(
  [for (final id in ids.toSet()) ?rows.getById(id)],
  registry: registry,
  environmentName: (id) => environments.getById(id)?.name,
);
