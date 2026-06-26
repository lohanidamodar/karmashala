import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/git_worktree.dart';

/// Raised when a `git` invocation fails (non-zero exit). Carries git's stderr
/// for an actionable diagnostic.
class GitException implements Exception {
  GitException(this.message);
  final String message;
  @override
  String toString() => 'GitException: $message';
}

/// Parses `git worktree list --porcelain` output into [GitWorktree]s.
///
/// Pure and testable. Records are separated by blank lines; each starts with a
/// `worktree <path>` line and may carry `HEAD <sha>`, `branch refs/heads/<name>`,
/// `bare`, or `detached` lines. Paths are bound to [environmentId].
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

/// Computes the directory for a session worktree of [repo].
///
/// Worktrees are placed in a sibling `.chitragupta-worktrees/` folder so they
/// never nest inside the repository. Path joining is **environment-aware**
/// (Windows vs POSIX separators) so Windows and WSL paths stay valid.
EnvironmentPath worktreePathFor(
  EnvironmentKind kind,
  EnvironmentPath repo,
  String worktreeName,
) {
  final ctx = kind == EnvironmentKind.windowsNative ? p.windows : p.posix;
  final parent = ctx.dirname(repo.path);
  final base = ctx.basename(repo.path);
  final dir = ctx.join(parent, '.chitragupta-worktrees', '$base-$worktreeName');
  return EnvironmentPath(environmentId: repo.environmentId, path: dir);
}

/// Git operations for a single environment, executed through a [CommandRunner].
///
/// Git is the authoritative source of repository changes (ADR 0004); this service
/// only invokes `git` and parses its output — it never tracks changes itself. The
/// [runner] must target the same environment as the paths passed in.
class GitService {
  GitService(this.runner);

  final CommandRunner runner;

  Future<CommandResult> _git(EnvironmentPath repo, List<String> args) async {
    final result = await runner.run(
      CommandRequest(executable: 'git', arguments: ['-C', repo.path, ...args]),
    );
    return result;
  }

  /// Whether [repo] is inside a Git work tree.
  Future<bool> isGitRepository(EnvironmentPath repo) async {
    try {
      final result = await _git(repo, ['rev-parse', '--is-inside-work-tree']);
      return result.ok && result.stdout.trim() == 'true';
    } on CommandException {
      return false;
    }
  }

  /// The current branch name of [repo], or `null` if detached/unknown.
  Future<String?> currentBranch(EnvironmentPath repo) async {
    final result = await _git(repo, ['rev-parse', '--abbrev-ref', 'HEAD']);
    if (!result.ok) return null;
    final name = result.stdout.trim();
    return (name.isEmpty || name == 'HEAD') ? null : name;
  }

  /// Lists the worktrees of [repo].
  Future<List<GitWorktree>> listWorktrees(EnvironmentPath repo) async {
    final result = await _git(repo, ['worktree', 'list', '--porcelain']);
    if (!result.ok) {
      throw GitException('git worktree list failed: ${result.stderr.trim()}');
    }
    return parseWorktreeList(result.stdout, repo.environmentId);
  }

  /// Adds a worktree at [worktreePath] checking out a new [branch] (optionally
  /// based on [baseRef]). Returns the created worktree.
  Future<GitWorktree> addWorktree(
    EnvironmentPath repo, {
    required EnvironmentPath worktreePath,
    required String branch,
    String? baseRef,
  }) async {
    final result = await _git(repo, [
      'worktree',
      'add',
      '-b',
      branch,
      worktreePath.path,
      ?baseRef,
    ]);
    if (!result.ok) {
      throw GitException('git worktree add failed: ${result.stderr.trim()}');
    }
    return GitWorktree(path: worktreePath, branch: branch);
  }

  /// Removes the worktree at [worktreePath]. Pass [force] to discard changes.
  Future<void> removeWorktree(
    EnvironmentPath repo,
    EnvironmentPath worktreePath, {
    bool force = false,
  }) async {
    final result = await _git(repo, [
      'worktree',
      'remove',
      if (force) '--force',
      worktreePath.path,
    ]);
    if (!result.ok) {
      throw GitException('git worktree remove failed: ${result.stderr.trim()}');
    }
  }
}
