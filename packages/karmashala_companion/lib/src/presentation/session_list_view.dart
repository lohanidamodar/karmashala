/// What the Projects tab draws once the host has sent something, decided
/// without a widget in sight.
library;

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import '../application/companion_environments.dart';
import 'companion_search.dart';
import 'project_group.dart';
import 'running_sessions_group.dart';

/// One of the four things the Projects tab can be showing.
sealed class SessionListView {
  const SessionListView();
}

/// Several machines and none chosen: which machine, before which project.
final class EnvironmentPick extends SessionListView {
  const EnvironmentPick(this.environments);

  final List<CompanionEnvironment> environments;
}

/// A desktop with one project that has sessions: its rows, with the running
/// ones lifted above the rest.
final class SingleProject extends SessionListView {
  const SingleProject({
    required this.group,
    required this.running,
    required this.rest,
    this.machine,
  });

  final CompanionProjectGroup group;
  final List<CompanionSessionSummary> running;
  final List<CompanionSessionSummary> rest;

  /// The machine chosen to get here, so the screen can offer the way back.
  final CompanionEnvironment? machine;
}

/// The project index, with every running session pinned above it.
final class ProjectIndex extends SessionListView {
  const ProjectIndex({
    required this.groups,
    required this.running,
    this.machine,
  });

  final List<CompanionProjectGroup> groups;
  final List<CompanionSessionSummary> running;
  final CompanionEnvironment? machine;
}

/// The search matched nothing in the snapshot in hand.
final class NoMatch extends SessionListView {
  const NoMatch();
}

/// The view for [sessions] and [projects] (null while the workspace has not
/// arrived), scoped to [chosenEnvironment] and filtered by [rawQuery].
///
/// A [chosenEnvironment] naming no machine here is a machine since switched
/// away from, and reads as "all of them" rather than as an empty list.
SessionListView sessionListViewOf({
  required List<CompanionSessionSummary> sessions,
  required List<RemoteWorkspaceProject>? projects,
  required String? chosenEnvironment,
  required String rawQuery,
}) {
  final query = companionSearchQuery(rawQuery);
  final machines = companionEnvironments(
    sessions,
    projects: projects ?? const [],
  );
  final active = machines.any((m) => m.key == chosenEnvironment)
      ? chosenEnvironment
      : null;
  if (machines.length > 1 && active == null && query.isEmpty) {
    return EnvironmentPick(machines);
  }
  // One machine needs no step, and a search crosses all of them.
  final scoped = active == null
      ? sessions
      : sessionsOnEnvironment(sessions, active);
  final machine = active == null
      ? null
      : machines.firstWhere((m) => m.key == active);

  // Scoped like the sessions, and by the same key: an unfiltered list put
  // every machine's projects behind every machine's row.
  final metadata = projects == null || active == null
      ? projects
      : projectsOnEnvironment(projects, active);
  final groups = metadata == null
      ? groupByProject(scoped)
      : mergeProjectsAndSessions(metadata, scoped);
  final shown = companionMatchingGroups(groups, query);

  if (groups.length == 1 && groups.single.sessions.isNotEmpty) {
    final only = shown.firstOrNull;
    if (only == null || only.sessions.isEmpty) return const NoMatch();
    final split = partitionByRunning(only.sessions);
    return SingleProject(
      group: only,
      running: split.running,
      rest: split.rest,
      machine: machine,
    );
  }
  if (shown.isEmpty) return const NoMatch();
  return ProjectIndex(
    groups: shown,
    running: [
      for (final group in shown) ...partitionByRunning(group.sessions).running,
    ],
    machine: machine,
  );
}
