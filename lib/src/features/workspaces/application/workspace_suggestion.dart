import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../../projects/domain/project.dart';

/// Suggests which context a project at [root] probably belongs to, by looking
/// at where the already-filed projects live.
///
/// **Suggest, never classify.** The answer is a prefilled, editable guess shown
/// in the New project dialog; nothing here assigns anything, and nothing here
/// ever looks at a project that already exists. Filing something in the wrong
/// context silently is worse than asking.
///
/// **Learned, not hard-coded.** The owner's game projects live under
/// `C:\Users\dlohani\projects\games\` and PopupBits under
/// `projects/popupbits/projects/`, but those are facts about one machine. What
/// generalises is that projects in the same context sit near each other on
/// disk, so the rule is: whichever context already holds a project sharing the
/// longest directory prefix with [root] wins.
///
/// Deliberately conservative in three ways, because a wrong guess costs the
/// user a correction on every new project:
///
/// * **Ties lose.** Two contexts matching equally well is a question, not an
///   answer — a new folder under `…\projects\` is as much PopupBits as it is
///   games — so nothing is suggested.
/// * **Four segments minimum.** `C:\Users\dlohani` and `/home/dlohani` are
///   three, and every project on the machine shares them; agreeing that far is
///   agreeing about nothing.
/// * **One namespace at a time.** A WSL root (`/mnt/c/src/x`), an SSH root and
///   a Windows root are different namespaces that happen to be spelled with
///   the same characters, so only projects in the *same* environment are
///   consulted. That also picks the path style: how a stored root is spelled
///   is what says whether it is a Windows path, matching `canonicalPathKey`.
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

/// How a path is spelled says which style it is: a drive letter or a UNC prefix
/// means Windows, anything else is POSIX — the same rule `canonicalPathKey`
/// uses, and the one that keeps WSL and SSH roots (both POSIX) correct.
p.Context pathContextFor(String path) =>
    RegExp(r'^[A-Za-z]:').hasMatch(path) || path.startsWith(r'\\')
    ? p.windows
    : p.posix;

/// Below this a shared prefix is not evidence of anything — `C:\Users\dlohani`
/// and `/home/dlohani` are three segments and everything on the machine is
/// under them.
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
