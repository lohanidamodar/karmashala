import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../domain/diff_stat.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/git_worktree.dart';
import '../domain/working_tree_status.dart';
import 'git_diff_parsing.dart';
import 'git_files.dart';

/// Raised when a `git` invocation fails (non-zero exit), carrying git's stderr.
class GitException implements Exception {
  GitException(this.message);
  final String message;
  @override
  String toString() => 'GitException: $message';
}

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

/// Git operations for one environment, executed through a [CommandRunner] that
/// must target the same environment as the paths passed in (ADR 0004).
class GitService {
  GitService(
    this.runner, {
    this.files = const HostGitFiles(),
    this.hostPathOf = sameEnvironmentPath,
  });

  final CommandRunner runner;

  /// Only the checkpoint machinery uses these; see [GitFiles].
  final GitFiles files;
  final HostPathOf hostPathOf;

  Future<CommandResult> _git(EnvironmentPath repo, List<String> args) async {
    final result = await runner.run(
      CommandRequest(executable: 'git', arguments: ['-C', repo.path, ...args]),
    );
    return result;
  }

  Future<String> _out(
    EnvironmentPath repo,
    List<String> args,
    String what,
  ) async {
    final result = await _git(repo, args);
    if (!result.ok) {
      throw GitException('git $what failed: ${result.stderr.trim()}');
    }
    return result.stdout.trim();
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

  /// The URL of [repo]'s `origin` remote, or `null` if there is none.
  Future<String?> remoteUrl(EnvironmentPath repo) async {
    final result = await _git(repo, ['remote', 'get-url', 'origin']);
    if (!result.ok) return null;
    final url = result.stdout.trim();
    return url.isEmpty ? null : url;
  }

  /// How many commits the current branch has that [base] does not. Null is
  /// "could not tell" — usually [base] is not fetched — and must not read as zero.
  Future<int?> commitsAhead(
    EnvironmentPath repo, {
    required String base,
  }) async {
    try {
      final result = await _git(repo, ['rev-list', '--count', '$base..HEAD']);
      if (!result.ok) return null;
      return int.tryParse(result.stdout.trim());
    } on CommandException {
      return null;
    }
  }

  /// Lines added and removed in [repo], from [base] to the working tree when
  /// given. No `git diff` sees untracked files, so this and `git status` can differ.
  Future<DiffStat?> diffStat(EnvironmentPath repo, {String? base}) async {
    try {
      final result = await _git(repo, ['diff', '--numstat', base ?? 'HEAD']);
      if (!result.ok) return null;
      return parseNumstat(result.stdout);
    } on CommandException {
      return null;
    }
  }

  /// How [repo]'s `HEAD` stands against [base], both directions in one call.
  Future<AheadBehind?> aheadBehind(
    EnvironmentPath repo, {
    required String base,
  }) async {
    try {
      final result = await _git(repo, [
        'rev-list',
        '--left-right',
        '--count',
        '$base...HEAD',
      ]);
      if (!result.ok) return null;
      return parseAheadBehind(result.stdout);
    } on CommandException {
      return null;
    }
  }

  /// The upstream branch of [branch] (`origin/work`), or null when it has none.
  ///
  /// `for-each-ref`, not `rev-parse @{upstream}`: no upstream is an empty answer
  /// rather than an error, and the format carries no braces for a remote shell.
  Future<String?> upstreamOf(EnvironmentPath repo, String branch) async {
    try {
      final result = await _git(repo, [
        'for-each-ref',
        '--format=%(upstream:short)',
        'refs/heads/$branch',
      ]);
      if (!result.ok) return null;
      final name = result.stdout.trim();
      return name.isEmpty ? null : name;
    } on CommandException {
      return null;
    }
  }

  /// Working-tree changes in [repo] (the review surface; Git is authoritative).
  Future<List<FileChange>> status(EnvironmentPath repo) async {
    final result = await _git(repo, ['status', '--porcelain=v1']);
    if (!result.ok) {
      throw GitException('git status failed: ${result.stderr.trim()}');
    }
    return parseGitStatus(result.stdout);
  }

  /// The branch, its upstream, their divergence and the changed files, from
  /// **one** `git status --porcelain=v2 --branch`.
  ///
  /// v2 for its header lines: divergence from the *upstream* comes free from a
  /// call already made, unlike [aheadBehind]'s comparison against the base branch.
  Future<WorkingTreeStatus> statusWithBranch(EnvironmentPath repo) async {
    final result = await _git(repo, ['status', '--porcelain=v2', '--branch']);
    if (!result.ok) {
      throw GitException('git status failed: ${result.stderr.trim()}');
    }
    return parseGitStatusV2(result.stdout);
  }

  /// The remote's default branch as this clone recorded it (`origin/main`).
  ///
  /// Null when `origin/HEAD` is not set, which a single-branch clone produces.
  Future<String?> originHead(EnvironmentPath repo) async {
    try {
      final result = await _git(repo, [
        'rev-parse',
        '--abbrev-ref',
        'origin/HEAD',
      ]);
      if (!result.ok) return null;
      final name = result.stdout.trim();
      return (name.isEmpty || name == 'origin/HEAD') ? null : name;
    } on CommandException {
      return null;
    }
  }

  /// Returns the unified diff for [repo], optionally limited to [path] and/or the
  /// staged (index) changes.
  Future<String> diff(
    EnvironmentPath repo, {
    String? path,
    bool staged = false,
  }) async {
    final result = await _git(repo, [
      'diff',
      if (staged) '--staged',
      if (path != null) ...['--', path],
    ]);
    if (!result.ok) {
      throw GitException('git diff failed: ${result.stderr.trim()}');
    }
    return result.stdout;
  }

  /// The blob sha each of [paths] would have for its **current bytes on disk**;
  /// `git hash-object` writes nothing, and the sha is only a fingerprint. A path
  /// missing from the result is one git would not hash — "cannot tell", never
  /// unchanged.
  ///
  /// The batch aborts on the first unreadable path, so a failure is retried one
  /// path at a time.
  Future<Map<String, String>> hashObjects(
    EnvironmentPath repo,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return const {};
    final batch = await _git(repo, ['hash-object', '--', ...paths]);
    if (batch.ok) {
      final shas = batch.stdout
          .split(RegExp(r'[\r\n]+'))
          .where((line) => line.trim().isNotEmpty)
          .toList();
      // A count mismatch means the output is not the row-per-path contract assumed here.
      if (shas.length == paths.length) {
        return {
          for (var i = 0; i < paths.length; i++) paths[i]: shas[i].trim(),
        };
      }
    }
    final one = <String, String>{};
    for (final path in paths) {
      final result = await _git(repo, ['hash-object', '--', path]);
      if (!result.ok) continue;
      final sha = result.stdout.trim();
      if (sha.isNotEmpty) one[path] = sha;
    }
    return one;
  }

  /// Recent commits on [repo]'s current branch.
  Future<List<GitCommit>> log(EnvironmentPath repo, {int limit = 20}) async {
    final result = await _git(repo, [
      'log',
      '-n',
      '$limit',
      '--pretty=format:%H%x1f%an%x1f%s',
    ]);
    if (!result.ok) {
      throw GitException('git log failed: ${result.stderr.trim()}');
    }
    return parseGitLog(result.stdout);
  }

  /// Stages all changes (`git add -A`).
  Future<void> stageAll(EnvironmentPath repo) async {
    final result = await _git(repo, ['add', '-A']);
    if (!result.ok) {
      throw GitException('git add failed: ${result.stderr.trim()}');
    }
  }

  /// Commits staged changes with [message].
  Future<void> commit(EnvironmentPath repo, String message) async {
    final result = await _git(repo, ['commit', '-m', message]);
    if (!result.ok) {
      throw GitException('git commit failed: ${result.stderr.trim()}');
    }
  }

  /// Creates and checks out a new branch [name].
  Future<void> createBranch(EnvironmentPath repo, String name) async {
    final result = await _git(repo, ['checkout', '-b', name]);
    if (!result.ok) {
      throw GitException('git checkout -b failed: ${result.stderr.trim()}');
    }
  }

  /// Merges [branch] into the branch currently checked out in [repo].
  Future<void> mergeBranch(EnvironmentPath repo, String branch) async {
    final result = await _git(repo, ['merge', '--no-ff', branch]);
    if (!result.ok) {
      throw GitException('git merge failed: ${result.stderr.trim()}');
    }
  }

  /// Merges [ref] into the checked-out branch, fast-forwarding when it can.
  ///
  /// Unlike [mergeBranch], which forces a merge commit to record a choice. A
  /// branch with no commits of its own must not show a merge that never happened.
  /// `--no-edit` because no terminal is attached and git would open an editor.
  Future<void> mergeRef(EnvironmentPath repo, String ref) async {
    final result = await _git(repo, ['merge', '--no-edit', ref]);
    if (!result.ok) {
      throw GitException('git merge failed: ${result.stderr.trim()}');
    }
  }

  /// Undoes a merge that stopped with conflicts (`git merge --abort`).
  ///
  /// It does not throw: a repository with no merge in progress errors here, which
  /// would replace the caller's real diagnosis. Returns whether the tree came back clean.
  Future<bool> abortMerge(EnvironmentPath repo) async {
    final result = await _git(repo, ['merge', '--abort']);
    return result.ok;
  }

  /// Pushes the current branch (optionally to [remote], setting upstream).
  Future<void> push(
    EnvironmentPath repo, {
    String? remote,
    String? branch,
  }) async {
    final result = await _git(repo, [
      'push',
      if (remote != null && branch != null) ...['-u', remote, branch],
    ]);
    if (!result.ok) {
      throw GitException('git push failed: ${result.stderr.trim()}');
    }
  }

  /// The remote-tracking branches that contain [rev], or `null` when git could
  /// not answer.
  ///
  /// This is how "pushed" is asked: a branch merged and pushed with `main` never
  /// had an upstream of its own. Empty means **not pushed**, but these refs are
  /// only as fresh as the last fetch, so a stale clone answers empty wrongly.
  Future<List<String>?> remoteBranchesContaining(
    EnvironmentPath repo,
    String rev,
  ) async {
    try {
      final result = await _git(repo, [
        'branch',
        '--remotes',
        '--contains',
        rev,
        '--format=%(refname:short)',
      ]);
      if (!result.ok) return null;
      return [
        for (final line in result.stdout.split(RegExp(r'[\r\n]')))
          if (line.trim().isNotEmpty) line.trim(),
      ];
    } on CommandException {
      return null;
    }
  }

  /// Which of [paths] git ignores in [repo] — or **null when git could not be
  /// asked**, which is not the same as "none of them".
  ///
  /// No `--no-index`, on purpose: a path a pattern matches but that is *tracked*
  /// reads as not ignored, which is what worktree setup needs. Exit 1 means none
  /// matched and is an answer; anything above it is git refusing the question.
  Future<Set<String>?> ignoredPaths(
    EnvironmentPath repo,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return const <String>{};
    try {
      final result = await _git(repo, ['check-ignore', '--', ...paths]);
      if (result.exitCode > 1) return null;
      return {
        for (final line in result.stdout.split(RegExp(r'[\r\n]')))
          if (line.trim().isNotEmpty) line.trim(),
      };
    } on CommandException {
      return null;
    }
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

  /// Where this repository's private checkpoint index lives.
  Future<CheckpointGitDirs> checkpointDirs(EnvironmentPath repo) async {
    final gitDir = await _out(repo, [
      'rev-parse',
      '--absolute-git-dir',
    ], 'rev-parse --absolute-git-dir');
    final commonDir = await _out(repo, [
      'rev-parse',
      '--path-format=absolute',
      '--git-common-dir',
    ], 'rev-parse --git-common-dir');
    return CheckpointGitDirs(gitDir: gitDir, commonDir: commonDir);
  }

  /// Creates the shadow git directory if it is not there yet.
  ///
  /// `commondir` plus `HEAD` is all git needs to treat a directory inside `.git`
  /// as a repository whose *index* alone is separate — that is the whole trick.
  /// `HEAD` names a branch that never exists so a stray command cannot move a real one.
  Future<void> ensureCheckpointDirs(
    EnvironmentPath repo,
    CheckpointGitDirs dirs,
  ) async {
    final shadow = hostPathOf(dirs.shadowGitDir);
    if (await files.exists('$shadow/HEAD')) return;
    await files.createDirectory(shadow);
    await files.writeString('$shadow/commondir', '${dirs.commonDir}\n');
    await files.writeString(
      '$shadow/HEAD',
      'ref: refs/heads/$kCheckpointHeadBranch\n',
    );
  }

  /// Stages the whole working tree into the private index and writes it out as
  /// a tree object. Returns the tree's sha.
  ///
  /// The user's index, HEAD, working tree and branches are untouched; only new
  /// objects appear, which [updateRef] then makes reachable so `git gc` keeps them.
  Future<String> writeWorkingTree(
    EnvironmentPath repo,
    CheckpointGitDirs dirs,
  ) async {
    final scope = [
      '--git-dir=${dirs.shadowGitDir}',
      '--work-tree=${repo.path}',
    ];
    final staged = await _git(repo, [...scope, 'add', '-A']);
    if (!staged.ok) {
      throw GitException(
        'git add (checkpoint index) failed: '
        '${staged.stderr.trim()}',
      );
    }
    return _out(repo, [...scope, 'write-tree'], 'write-tree');
  }

  /// Wraps [tree] in a commit so checkpoints form a chain a single ref can hold.
  ///
  /// The identity is passed per invocation because `commit-tree` fails outright
  /// in a repository where no `user.email` is configured.
  Future<String> commitTree(
    EnvironmentPath repo, {
    required String tree,
    String? parent,
    required String message,
  }) => _out(repo, [
    '-c',
    'user.name=$kCheckpointAuthorName',
    '-c',
    'user.email=$kCheckpointAuthorEmail',
    'commit-tree',
    tree,
    if (parent != null) ...['-p', parent],
    '-m',
    message,
  ], 'commit-tree');

  /// Points [ref] at [sha]. Refs under `refs/karmashala/` are invisible to
  /// `git branch`, `git log` and `git status`, and are never pushed.
  Future<void> updateRef(EnvironmentPath repo, String ref, String sha) async {
    final result = await _git(repo, ['update-ref', ref, sha]);
    if (!result.ok) {
      throw GitException('git update-ref failed: ${result.stderr.trim()}');
    }
  }

  /// Removes [ref]. Missing refs are not an error — deleting a checkpoint that
  /// is already gone is the outcome the caller wanted.
  Future<void> deleteRef(EnvironmentPath repo, String ref) async {
    await _git(repo, ['update-ref', '-d', ref]);
  }

  /// Resolves [rev], or `null` when it does not exist — an unborn `HEAD` in a
  /// repository with no commits included.
  Future<String?> revParse(EnvironmentPath repo, String rev) async {
    try {
      final result = await _git(repo, [
        'rev-parse',
        '--verify',
        '--quiet',
        rev,
      ]);
      final sha = result.stdout.trim();
      return (!result.ok || sha.isEmpty) ? null : sha;
    } on CommandException {
      return null;
    }
  }

  /// The diff between two objects — two checkpoint trees, or a tree and the
  /// working tree when [to] is omitted.
  Future<String> diffObjects(
    EnvironmentPath repo, {
    required String from,
    String? to,
    List<String> paths = const [],
    bool binary = true,
  }) async {
    final result = await _git(repo, [
      'diff',
      '--no-color',
      if (binary) '--binary',
      from,
      ?to,
      if (paths.isNotEmpty) ...['--', ...paths],
    ]);
    if (!result.ok) {
      throw GitException('git diff failed: ${result.stderr.trim()}');
    }
    return result.stdout;
  }

  /// `git diff --name-status` between two objects, as [FileChange]s.
  Future<List<FileChange>> diffNameStatus(
    EnvironmentPath repo, {
    required String from,
    String? to,
  }) async {
    final result = await _git(repo, [
      'diff',
      '--name-status',
      '--no-renames',
      from,
      ?to,
    ]);
    if (!result.ok) {
      throw GitException(
        'git diff --name-status failed: '
        '${result.stderr.trim()}',
      );
    }
    return parseNameStatus(result.stdout);
  }

  /// Applies [patch] to [repo].
  ///
  /// [cached] applies to the index only, [reverse] applies it backwards, [check]
  /// only asks whether it would apply. The patch is written inside the shadow git
  /// directory: a scratch file in the working tree would show in `git status`.
  Future<void> applyPatch(
    EnvironmentPath repo,
    CheckpointGitDirs dirs,
    String patch, {
    bool reverse = false,
    bool cached = false,
    bool check = false,
  }) async {
    if (patch.trim().isEmpty) {
      throw GitException('Refusing to apply an empty patch.');
    }
    await ensureCheckpointDirs(repo, dirs);
    await files.writeString(hostPathOf(dirs.patchFile), patch);
    final result = await _git(repo, [
      'apply',
      if (reverse) '-R',
      if (cached) '--cached',
      if (check) '--check',
      dirs.patchFile,
    ]);
    if (!result.ok) {
      throw GitException('git apply failed: ${result.stderr.trim()}');
    }
  }
}

/// The branch name in the shadow git directory's `HEAD`. It never exists.
const kCheckpointHeadBranch = 'karmashala-checkpoints';

/// Who checkpoint commits are attributed to — a label, since they are never pushed.
const kCheckpointAuthorName = 'Karmashala';
const kCheckpointAuthorEmail = 'checkpoints@karmashala.local';

/// Where the private checkpoint index and its scratch patch live.
class CheckpointGitDirs {
  const CheckpointGitDirs({required this.gitDir, required this.commonDir});

  /// This working tree's own git directory. For a linked worktree that is
  /// `<repo>/.git/worktrees/<name>`, not `<repo>/.git`.
  final String gitDir;

  /// The git directory the objects and refs live in, shared by every worktree.
  final String commonDir;

  String get shadowGitDir => '$gitDir/karmashala';
  String get patchFile => '$shadowGitDir/apply.patch';
}
