import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';

import 'project.dart';
import 'stored_section.dart';
import 'workspace.dart';

/// The rules every copy of the workspace follows — the server applies them to
/// its writes, and a client's copy reads in the same orders.

/// Oldest first — the order the `projects` table is read in, before pins.
int compareProjects(Project a, Project b) {
  final byAge = a.createdAt.compareTo(b.createdAt);
  return byAge != 0 ? byAge : a.id.compareTo(b.id);
}

/// Oldest first, like projects: the first checkout is the picker's default.
int compareRepositories(Repository a, Repository b) {
  final byAge = a.createdAt.compareTo(b.createdAt);
  return byAge != 0 ? byAge : a.id.compareTo(b.id);
}

/// By name, ignoring case — the way a user scans four things they named.
int compareWorkspaces(Workspace a, Workspace b) {
  final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byName != 0 ? byName : a.id.compareTo(b.id);
}

/// Sidebar order, which is also priority order.
int compareSections(StoredSection a, StoredSection b) {
  final byPosition = a.position.compareTo(b.position);
  return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
}

/// A name as kept — trimmed — or null when nothing is left, which no
/// context, project or section may be called.
String? rowNameOf(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// A trimmed description, or null — an empty string is the absence of one,
/// never a description that happens to be blank.
String? descriptionOf(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Whether two context names are ones a picker could not tell apart.
bool sameContextName(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// A new project's checkouts: what discovery [found] under its root, or —
/// with nothing found — the root itself. **Git is not the point**: every agent
/// CLI starts in a plain directory, so a folder is enough to run in.
List<Repository> checkoutsForNewProject(
  Project project,
  Iterable<DiscoveredRepository> found, {
  required String Function() newId,
}) => checkoutsToAdd(project, const [], found, newId: newId, orRoot: true);

/// The checkouts to record for [project], which already has [existing]: each
/// of [found] not already recorded (by where it is, not how it is spelled),
/// and — with [orRoot], when the project would still have nowhere to run —
/// its root folder.
List<Repository> checkoutsToAdd(
  Project project,
  Iterable<Repository> existing,
  Iterable<DiscoveredRepository> found, {
  required String Function() newId,
  bool orRoot = false,
  DateTime? now,
}) {
  final at = now ?? project.createdAt;
  final known = {for (final repository in existing) Checkout(repository.path)};
  final added = <Repository>[
    for (final discovered in found)
      if (known.add(Checkout(discovered.path)))
        Repository(
          id: newId(),
          projectId: project.id,
          name: discovered.name,
          path: discovered.path,
          createdAt: at,
        ),
  ];
  if (orRoot && known.isEmpty) {
    added.add(
      Repository(
        id: newId(),
        projectId: project.id,
        name: project.name,
        path: project.root,
        createdAt: at,
      ),
    );
  }
  return added;
}

/// A project's root moved from [from] to [to]: each checkout under the old
/// root, rewritten under the new one keeping its id (every session, worktree
/// and setting references it), and the ones that were not under it — nothing
/// here knows where they went, so they are reported, not guessed at.
({List<Repository> rebased, List<Repository> leftBehind}) rebaseCheckouts(
  EnvironmentPath from,
  EnvironmentPath to,
  Iterable<Repository> checkouts,
) {
  final rebased = <Repository>[];
  final leftBehind = <Repository>[];
  for (final repository in checkouts) {
    final relative = _relativeUnder(from, repository.path);
    if (relative == null) {
      leftBehind.add(repository);
    } else {
      rebased.add(repository.copyWith(path: _underRoot(to, relative)));
    }
  }
  return (rebased: rebased, leftBehind: leftBehind);
}

/// Whether a root at [to] is somewhere else than [from].
bool rootMoves(EnvironmentPath from, EnvironmentPath to) =>
    Checkout(from) != Checkout(to);

/// [child] written relative to [root] using paths alone, so a root that also
/// changes environment still carries its checkouts across. `''` when they are
/// the same folder, null when [child] is not underneath.
String? _relativeUnder(EnvironmentPath root, EnvironmentPath child) {
  if (root.environmentId != child.environmentId) return null;
  final parent = canonicalPathKey(root.path);
  final under = canonicalPathKey(child.path);
  if (under == parent) return '';
  if (!under.startsWith('$parent/')) return null;
  return child.path.replaceAll(r'\', '/').substring(parent.length + 1);
}

/// [relative] joined onto [root] in the spelling [root] is written in — a
/// Windows root keeps backslashes, a POSIX one keeps forward slashes.
EnvironmentPath _underRoot(EnvironmentPath root, String relative) {
  if (relative.isEmpty) return root;
  final windowsStyle =
      RegExp(r'^[A-Za-z]:').hasMatch(root.path) || root.path.startsWith(r'\\');
  final base = root.path.replaceAll(RegExp(r'[\\/]+$'), '');
  final tail = windowsStyle ? relative.replaceAll('/', r'\') : relative;
  return EnvironmentPath(
    environmentId: root.environmentId,
    path: windowsStyle ? '$base\\$tail' : '$base/$tail',
  );
}
