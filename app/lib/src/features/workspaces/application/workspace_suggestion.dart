import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../../projects/domain/project.dart';

/// Suggests which context a project at [root] probably belongs to: whichever
/// already holds a project sharing the longest path prefix. Ties suggest nothing.
String? suggestWorkspaceForRoot({
  required EnvironmentPath root,
  required Iterable<Project> projects,
}) {
  final context = pathContextFor(root.path);
  final target = _segments(context, root.path);
  if (target.isEmpty) return null;

  final best = <String, int>{};
  for (final project in projects) {
    final workspaceId = project.workspaceId;
    if (workspaceId == null) continue;
    if (project.root.environmentId != root.environmentId) continue;
    final shared = _sharedPrefix(
      target,
      _segments(context, project.root.path),
      caseInsensitive: context == p.windows,
    );
    if (shared < _minimumEvidence) continue;
    final current = best[workspaceId];
    if (current == null || shared > current) best[workspaceId] = shared;
  }
  if (best.isEmpty) return null;

  var winner = '';
  var top = 0;
  var tied = false;
  for (final entry in best.entries) {
    if (entry.value > top) {
      top = entry.value;
      winner = entry.key;
      tied = false;
    } else if (entry.value == top) {
      tied = true;
    }
  }
  return tied ? null : winner;
}

/// How a path is spelled says which style it is — a drive letter or a UNC
/// prefix means Windows. The same rule `canonicalPathKey` uses.
p.Context pathContextFor(String path) =>
    RegExp(r'^[A-Za-z]:').hasMatch(path) || path.startsWith(r'\\')
    ? p.windows
    : p.posix;

/// Below this a shared prefix is not evidence: `/home/dlohani` is three
/// segments and everything on the machine is under them.
const _minimumEvidence = 4;

List<String> _segments(p.Context context, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return const [];
  return context.split(context.normalize(trimmed));
}

int _sharedPrefix(
  List<String> a,
  List<String> b, {
  required bool caseInsensitive,
}) {
  final limit = a.length < b.length ? a.length : b.length;
  var shared = 0;
  while (shared < limit) {
    final left = a[shared];
    final right = b[shared];
    final same = caseInsensitive
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
    if (!same) break;
    shared++;
  }
  return shared;
}
