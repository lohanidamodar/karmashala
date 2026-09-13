import 'package:agent_cli/process.dart';

import '../../projects/domain/project.dart';

/// One environment's worth of the Explorer, with the projects that run there.
class EnvironmentGroup {
  const EnvironmentGroup({
    required this.environmentId,
    required this.environment,
    required this.projects,
  });

  final String environmentId;

  /// The row this group is about, or null when a project names an environment
  /// the workspace no longer has. Null is shown as the bare id rather than
  /// folded into the local machine: a project that ran somewhere else did not
  /// move here just because the record went.
  final ExecutionEnvironment? environment;

  final List<Project> projects;

  /// What the group calls itself. The environment's own name where there is
  /// one, because that is what the user typed when they added the host.
  String get label => environment?.name ?? environmentId;
}

/// Groups [projects] by the environment they run in, in the order a person
/// reads them: this machine first, then its WSL distributions, then the
/// machines reached over SSH, then anything whose environment is missing.
/// Within a kind, by name, so the list does not reshuffle between builds.
/// [includeEmpty] adds a group for every environment holding no project at
/// all. The Explorer wants them — a machine with nothing on it is where a
/// terminal is opened, and leaving it out would say it is not there (§19).
List<EnvironmentGroup> groupProjectsByEnvironment(
  List<Project> projects,
  List<ExecutionEnvironment> environments, {
  bool includeEmpty = false,
}) {
  final byId = {for (final e in environments) e.id: e};
  final grouped = <String, List<Project>>{};
  if (includeEmpty) {
    for (final environment in environments) {
      grouped[environment.id] = [];
    }
  }
  for (final project in projects) {
    grouped.putIfAbsent(project.root.environmentId, () => []).add(project);
  }

  final groups = [
    for (final entry in grouped.entries)
      EnvironmentGroup(
        environmentId: entry.key,
        environment: byId[entry.key],
        projects: entry.value,
      ),
  ]..sort((a, b) {
    final rank = _rank(a.environment).compareTo(_rank(b.environment));
    if (rank != 0) return rank;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return groups;
}

/// Local before WSL before SSH before an environment we no longer hold.
int _rank(ExecutionEnvironment? environment) => switch (environment?.kind) {
  EnvironmentKind.windowsNative || EnvironmentKind.localPosix => 0,
  EnvironmentKind.wsl => 1,
  EnvironmentKind.ssh => 2,
  null => 3,
};
