import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../domain/git_branch_ref.dart';
import '../domain/git_worktree.dart';
import 'git_service.dart' show GitService;

/// Parses `git worktree list --porcelain` into [GitWorktree]s bound to [environmentId].
List<GitWorktree> parseWorktreeList(String porcelain, String environmentId) {
  final worktrees = <GitWorktree>[];
  String? path;
  String? head;
  String? branch;
  var bare = false;

  void flush() {
    if (path != null) {
      worktrees.add(
        GitWorktree(
          path: EnvironmentPath(environmentId: environmentId, path: path!),
          head: head,
          branch: branch,
          isBare: bare,
        ),
      );
    }
    path = null;
    head = null;
    branch = null;
    bare = false;
  }

  for (final raw in porcelain.split(RegExp(r'[\r\n]'))) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (line.startsWith('worktree ')) {
      flush();
      path = line.substring('worktree '.length);
    } else if (line.startsWith('HEAD ')) {
      head = line.substring('HEAD '.length);
    } else if (line.startsWith('branch ')) {
      branch = line.substring('branch '.length).replaceFirst('refs/heads/', '');
    } else if (line == 'bare') {
      bare = true;
    }
  }
  flush();
  return worktrees;
}

/// What [GitService.listBranches] asks `for-each-ref` to print per ref, tab
/// separated: a ref name can hold no control character, so a tab never splits
/// one.
const String kBranchRefFormat =
    '%(refname)%09%(HEAD)%09%(upstream:short)';

/// Parses `git for-each-ref --format=<kBranchRefFormat>` over `refs/heads` and
/// `refs/remotes`. A remote's symbolic `HEAD` (`origin/HEAD`) is not a branch
/// anyone can pick, so it is left out.
List<GitBranchRef> parseBranchRefs(String output) {
  final refs = <GitBranchRef>[];
  for (final raw in output.split(RegExp(r'[\r\n]'))) {
    if (raw.trim().isEmpty) continue;
    final fields = raw.split('\t');
    final refname = fields[0].trim();
    final current = fields.length > 1 && fields[1].trim() == '*';
    final upstream = fields.length > 2 && fields[2].trim().isNotEmpty
        ? fields[2].trim()
        : null;
    if (refname.startsWith('refs/heads/')) {
      refs.add(
        GitBranchRef(
          name: refname.substring('refs/heads/'.length),
          isCurrent: current,
          upstream: upstream,
        ),
      );
    } else if (refname.startsWith('refs/remotes/')) {
      final short = refname.substring('refs/remotes/'.length);
      final slash = short.indexOf('/');
      if (slash <= 0 || short.endsWith('/HEAD')) continue;
      refs.add(GitBranchRef(name: short, remote: short.substring(0, slash)));
    }
  }
  return refs;
}

/// The directory for a session worktree of [repo]: a sibling
/// `.karmashala-worktrees/` so it never nests, joined with [kind]'s separators.
EnvironmentPath worktreePathFor(
  EnvironmentKind kind,
  EnvironmentPath repo,
  String worktreeName,
) {
  final ctx = usesWindowsPaths(kind) ? p.windows : p.posix;
  final parent = ctx.dirname(repo.path);
  final base = ctx.basename(repo.path);
  final dir = ctx.join(parent, '.karmashala-worktrees', '$base-$worktreeName');
  return EnvironmentPath(environmentId: repo.environmentId, path: dir);
}
