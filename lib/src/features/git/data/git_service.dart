import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/diff_stat.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/git_worktree.dart';
import '../domain/working_tree_status.dart';
import 'git_diff_parsing.dart';
import 'git_files.dart';

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

  /// How many commits the current branch has that [base] does not, or `null`
  /// when git could not answer — typically because [base] (e.g.
  /// `origin/main`) is not fetched locally. `null` means "could not tell", not
  /// "zero"; callers must not collapse the two.
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

  /// Lines added and removed in [repo] — one `git diff --numstat`.
  ///
  /// With [base], the comparison runs from that ref to the working tree, so a
  /// session's committed *and* uncommitted work land in one number from one
  /// process. Without it, the working tree is compared to `HEAD`.
  ///
  /// Untracked files are in neither, because no `git diff` sees them. That is
  /// why the changed-file count beside this still comes from `git status`, and
  /// why the two can legitimately disagree. Null is "could not tell".
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
  ///
  /// [commitsAhead] answers half of this and is kept because the Explorer's
  /// per-row path only needs the half; anything deciding a delivery stage needs
  /// both, and paying for two `rev-list` runs to learn them would be silly.
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
  /// `for-each-ref` rather than `rev-parse @{upstream}`: a branch with no
  /// upstream is an ordinary empty answer here instead of an error, and the
  /// format string carries no braces for a remote shell to interpret.
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
  /// **one** `git status --porcelain=v1 --branch`.
  ///
  /// This is what a delivery row wants and it costs one process. [status] is
  /// kept for callers that only need the files.
  Future<WorkingTreeStatus> statusWithBranch(EnvironmentPath repo) async {
    final result = await _git(repo, ['status', '--porcelain=v1', '--branch']);
    if (!result.ok) {
      throw GitException('git status failed: ${result.stderr.trim()}');
    }
    return parseGitStatusBranch(result.stdout);
  }

  /// The remote's default branch as this clone recorded it (`origin/main`).
  ///
  /// Local and free, unlike `gh repo view`. Null when `origin/HEAD` is not set,
  /// which a single-branch clone and an older `git remote add` both produce.
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

  // --- checkpoints -----------------------------------------------------------

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
  /// Two files make a directory inside `.git` into something git will accept as
  /// a repository of its own: `commondir`, pointing at the real one, and `HEAD`.
  /// Objects, refs and config then come from the real repository — only the
  /// *index* is separate, which is the whole trick. `git
  /// --git-dir=$shadow --work-tree=$repo add -A` stages the entire working tree, untracked files
  /// included, into an index the user does not own, and `git write-tree` turns
  /// it into a tree object in the repository's own object store.
  ///
  /// `HEAD` deliberately names a branch that does not exist. Nothing here reads
  /// it — `add` and `write-tree` do not need a commit — and pointing it at a
  /// real branch would risk a stray command in this directory moving one.
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
  /// The user's index, HEAD, working tree and branches are all untouched: the
  /// only thing that happens to the repository is that some objects appear in
  /// its object store, and [updateRef] then makes those reachable so `git gc`
  /// keeps them.
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
  /// The identity is passed per invocation rather than read from the user's
  /// config, because `commit-tree` fails outright in a repository where no
  /// identity is set, and a checkpoint must not depend on the user having got
  /// round to `git config user.email`.
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

  /// Points [ref] at [sha]. Refs under `refs/chitragupta/` are invisible to
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
  /// [cached] applies to the index only (staging a hunk), [reverse] applies it
  /// backwards (reverting one), and [check] asks git whether it *would* apply
  /// without changing anything. Without [cached] the index is not touched, so a
  /// revert in the working tree leaves whatever the user had staged alone.
  ///
  /// The patch goes to a file inside the shadow git directory rather than the
  /// repository: a stray file in the working tree would show up in the user's
  /// `git status` and, worse, in the next checkpoint.
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
const kCheckpointHeadBranch = 'chitragupta-checkpoints';

/// Who checkpoint commits are attributed to. They are never pushed and never
/// merged, so this is a label, not an identity claim.
const kCheckpointAuthorName = 'Chitragupta';
const kCheckpointAuthorEmail = 'checkpoints@chitragupta.local';

/// Where the private checkpoint index and its scratch patch live for one
/// repository or worktree.
class CheckpointGitDirs {
  const CheckpointGitDirs({required this.gitDir, required this.commonDir});

  /// This working tree's own git directory. For a linked worktree that is
  /// `<repo>/.git/worktrees/<name>`, not `<repo>/.git`.
  final String gitDir;

  /// The git directory the objects and refs actually live in, shared by every
  /// worktree of the repository.
  final String commonDir;

  String get shadowGitDir => '$gitDir/chitragupta';
  String get patchFile => '$shadowGitDir/apply.patch';
}
