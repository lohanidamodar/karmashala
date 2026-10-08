import 'dart:async';
import 'dart:io' show ProcessException;

import 'package:agent_cli/process.dart';
import '../domain/diff_stat.dart';
import '../domain/file_change.dart';
import '../domain/git_branch_ref.dart';
import '../domain/git_commit.dart';
import '../domain/git_worktree.dart';
import '../domain/working_tree_status.dart';
import '../domain/worktree_contents.dart';
import '../domain/worktree_creation.dart';
import 'git_diff_parsing.dart';
import 'git_files.dart';
import 'secret_scan.dart';
import 'checkpoint_git_dirs.dart';
import 'git_command_outcomes.dart';
import 'git_environment.dart';
import 'git_ref_parsing.dart';

export 'checkpoint_git_dirs.dart';
export 'git_command_outcomes.dart';
export 'git_environment.dart';
export 'git_ref_parsing.dart';

/// Git operations for one environment, executed through a [CommandRunner] that
/// must target the same environment as the paths passed in (ADR 0004).
class GitService {
  GitService(
    this.runner, {
    this.files = const HostGitFiles(),
    this.hostPathOf = sameEnvironmentPath,
    this.networkTimeout = const Duration(minutes: 5),
    this.mutationTimeout = const Duration(minutes: 2),
    this.untrackedFileLimit = 2000,
  });

  /// How many files of new folders a status lists; the rest of a folder are
  /// one row counting them, so a build output nobody ignored cannot hang a list.
  final int untrackedFileLimit;

  final CommandRunner runner;

  /// Only the checkpoint machinery uses these; see [GitFiles].
  final GitFiles files;
  final HostPathOf hostPathOf;

  /// How long a command that talks to a remote may take: a credential prompt
  /// nobody can see, or a stalled fetch, ends here instead of never.
  final Duration networkTimeout;

  /// How long a command that changes the repository may take. Reads get none.
  final Duration mutationTimeout;

  static const Set<String> _networkVerbs = {
    'push',
    'fetch',
    'pull',
    'clone',
    'ls-remote',
  };
  static const Set<String> _mutatingVerbs = {
    'add',
    'checkout',
    'commit',
    'merge',
    'update-ref',
    'worktree',
    'hash-object',
  };

  Duration? _timeoutFor(List<String> args) {
    final verb = args.firstOrNull;
    if (_networkVerbs.contains(verb)) return networkTimeout;
    if (_mutatingVerbs.contains(verb)) return mutationTimeout;
    return null;
  }

  Future<CommandResult> _git(EnvironmentPath repo, List<String> args) async {
    final result = await runner.run(
      CommandRequest(
        executable: 'git',
        arguments: ['-C', repo.path, ...args],
        timeout: _timeoutFor(args),
        environment: gitEnvironmentFor(args),
        removedEnvironment: kGitRemovedEnvironment,
      ),
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

  /// The root of the work tree [directory] is in, as git spells it, or `null`
  /// when it is in none or does not exist. A nested repository answers for
  /// itself, not for the one it sits inside.
  Future<String?> topLevel(EnvironmentPath directory) async {
    try {
      final result = await _git(directory, ['rev-parse', '--show-toplevel']);
      final root = result.stdout.trim();
      return result.ok && root.isNotEmpty ? root : null;
    } on CommandException {
      return null;
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

  /// Lines added and removed in [repo]'s working tree since `HEAD`, or since
  /// it branched from [base] when given. No `git diff` sees untracked files,
  /// so this and `git status` can differ.
  ///
  /// From the merge-base, not [base]'s tip: against the tip, every commit
  /// [base] gained after the branch left counted as this branch's work,
  /// reversed. The merge-base still moves when [base] is merged in, which a
  /// base commit recorded at creation would not.
  Future<DiffStat?> diffStat(EnvironmentPath repo, {String? base}) async {
    try {
      var result = await _git(repo, [
        'diff',
        '--numstat',
        if (base != null) ...['--merge-base', base] else 'HEAD',
      ]);
      // `--merge-base` is git 2.30; an older one is measured as before.
      if (!result.ok && base != null) {
        result = await _git(repo, ['diff', '--numstat', base]);
      }
      if (!result.ok) return null;
      return parseNumstat(result.stdout);
    } on CommandException {
      return null;
    }
  }

  /// Lines added and removed per file in [repo]'s working tree, from [base] (or
  /// `HEAD`).
  ///
  /// An absent path means "git did not say", never "nothing changed" — which is
  /// already true of every untracked file, and is why **empty on failure** is
  /// acceptable here: no count is invented, only withheld.
  Future<Map<String, FileDiffStat>> fileDiffStats(
    EnvironmentPath repo, {
    String? base,
  }) async {
    try {
      final result = await _git(repo, ['diff', '--numstat', base ?? 'HEAD']);
      if (!result.ok) return const {};
      return parseNumstatByFile(result.stdout);
    } on CommandException {
      return const {};
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
    return _withNewFolderFiles(repo, parseGitStatus(result.stdout));
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
    final status = parseGitStatusV2(result.stdout);
    return WorkingTreeStatus(
      branch: status.branch,
      upstream: status.upstream,
      aheadOfUpstream: status.aheadOfUpstream,
      behindUpstream: status.behindUpstream,
      changes: await _withNewFolderFiles(repo, status.changes),
    );
  }

  /// [changes] with each `dir/` git folded an untracked folder into replaced
  /// by the folder's files, up to [untrackedFileLimit].
  ///
  /// A second, narrow `ls-files` rather than `status -uall`, which would lose
  /// which folder is new; it runs only when there is one. A folder that cannot
  /// be listed is kept as git reported it.
  Future<List<FileChange>> _withNewFolderFiles(
    EnvironmentPath repo,
    List<FileChange> changes,
  ) async {
    final folders = [
      for (final c in changes)
        if (c.type == FileChangeType.untracked && c.path.endsWith('/')) c.path,
    ];
    if (folders.isEmpty) return changes;
    final CommandResult result;
    try {
      result = await _git(repo, [
        'ls-files',
        '-z',
        '--others',
        '--exclude-standard',
        '--full-name',
        '--',
        for (final folder in folders) ':(top,literal)$folder',
      ]);
    } on CommandException {
      return changes;
    }
    if (!result.ok) return changes;

    final filesOf = <String, List<String>>{for (final f in folders) f: []};
    for (final path in result.stdout.split('\x00')) {
      if (path.isEmpty) continue;
      final folder = folders.firstWhere(path.startsWith, orElse: () => '');
      if (folder.isNotEmpty) filesOf[folder]!.add(path);
    }

    var budget = untrackedFileLimit;
    final expanded = <FileChange>[];
    for (final change in changes) {
      final files = filesOf[change.path];
      if (files == null || files.isEmpty) {
        expanded.add(change);
        continue;
      }
      final name = change.path.substring(0, change.path.length - 1);
      files.sort();
      final listed = files.take(budget < 0 ? 0 : budget).toList();
      budget -= listed.length;
      for (final path in listed) {
        expanded.add(
          FileChange(
            path: path,
            type: FileChangeType.untracked,
            staged: false,
            unstaged: true,
            newFolder: name,
          ),
        );
      }
      if (files.length > listed.length) {
        expanded.add(
          FileChange(
            path: change.path,
            type: FileChangeType.untracked,
            staged: false,
            unstaged: true,
            newFolder: name,
            moreFiles: files.length - listed.length,
          ),
        );
      }
    }
    return expanded;
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
  ///
  /// [base] is what the diff is taken against: `HEAD` covers staged and unstaged
  /// together, which is what [fileDiffStats] counts. Omitted, it is unstaged only.
  Future<String> diff(
    EnvironmentPath repo, {
    String? path,
    bool staged = false,
    String? base,
  }) async {
    final result = await _git(repo, [
      'diff',
      if (staged) '--staged',
      ?base,
      if (path != null) ...['--', path],
    ]);
    if (!result.ok) {
      throw GitException('git diff failed: ${result.stderr.trim()}');
    }
    return result.stdout;
  }

  /// Whether git tracks [path] in [repo].
  ///
  /// `ls-files --error-unmatch` exits 0 for a tracked path and 1 for one it
  /// does not know. Anything above that is git refusing the question, and the
  /// answer is **tracked** — the conservative one, because it leaves every
  /// caller doing what it did before this method existed.
  Future<bool> isTracked(EnvironmentPath repo, String path) async {
    final result = await _git(repo, [
      'ls-files',
      '--error-unmatch',
      '--',
      path,
    ]);
    return result.exitCode != 1;
  }

  /// Unified diff for an **untracked** [path] in [repo], as an all-added file.
  ///
  /// `git diff` never sees untracked files, so this asks `--no-index` against
  /// the null device instead. Exit 1 is git's "these differ" answer — measured
  /// on both Windows and WSL git — and only above it is git refusing.
  Future<String> diffUntracked(EnvironmentPath repo, String path) async {
    final result = await _git(repo, [
      'diff',
      '--no-index',
      '--',
      '/dev/null',
      path,
    ]);
    if (result.exitCode > 1) {
      throw GitException('git diff --no-index failed: ${result.stderr.trim()}');
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

  /// Stages exactly [paths] — repository-relative, as `status` reports them.
  /// `--` because a path that looks like a revision is still a path.
  Future<void> stage(EnvironmentPath repo, List<String> paths) async {
    if (paths.isEmpty) return;
    final result = await _git(repo, ['add', '--', ...paths]);
    if (!result.ok) {
      throw GitException('git add failed: ${result.stderr.trim()}');
    }
  }

  /// Takes [paths] out of the index, leaving the working tree alone.
  ///
  /// `restore --staged` rather than `reset`: on a repository with no commits
  /// yet there is no HEAD to reset against, and unstaging the first file of a
  /// new repository is exactly when a user reaches for this.
  Future<void> unstage(EnvironmentPath repo, List<String> paths) async {
    if (paths.isEmpty) return;
    final result = await _git(repo, ['restore', '--staged', '--', ...paths]);
    if (!result.ok) {
      throw GitException(
        'git restore --staged failed: ${result.stderr.trim()}',
      );
    }
  }

  /// Throws away the working-tree changes to [paths], staged and unstaged
  /// alike. **Tracked files only** — an untracked file is not git's to delete,
  /// and [deleteUntracked] says so in its own name.
  Future<void> discard(EnvironmentPath repo, List<String> paths) async {
    if (paths.isEmpty) return;
    final result = await _git(repo, [
      'restore',
      '--staged',
      '--worktree',
      '--',
      ...paths,
    ]);
    if (!result.ok) {
      throw GitException('git restore failed: ${result.stderr.trim()}');
    }
  }

  /// Deletes untracked [paths] (`git clean -f --`), which is what "discard"
  /// means for a file git has never seen. Separate from [discard] because it
  /// removes a file rather than rewinding one, and nothing undoes it.
  Future<void> deleteUntracked(EnvironmentPath repo, List<String> paths) async {
    if (paths.isEmpty) return;
    final result = await _git(repo, ['clean', '-f', '-d', '--', ...paths]);
    if (!result.ok) {
      throw GitException('git clean failed: ${result.stderr.trim()}');
    }
  }

  /// Updates the remote-tracking refs without touching the working tree.
  Future<void> fetch(EnvironmentPath repo, {String? remote}) async {
    final result = await _git(repo, ['fetch', ?remote, '--prune']);
    if (!result.ok) {
      throw GitException('git fetch failed: ${result.stderr.trim()}');
    }
  }

  /// Brings the upstream's commits into the checked-out branch.
  ///
  /// `--ff-only` by default: nothing here is attended, and a pull that stops
  /// with conflicts in a checkout an agent is working in is a worse outcome
  /// than a refusal the caller can show. [rebase] and [merge] are the two ways
  /// to say "do it anyway", and they are the user's to choose.
  Future<void> pull(
    EnvironmentPath repo, {
    bool rebase = false,
    bool merge = false,
  }) async {
    final result = await _git(repo, [
      'pull',
      if (rebase) '--rebase' else if (merge) '--no-rebase' else '--ff-only',
      if (merge) '--no-edit',
    ]);
    if (!result.ok) {
      throw GitException('git pull failed: ${result.stderr.trim()}');
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

  /// Scans the commits a push of [repo] would send for secrets, with gitleaks
  /// where the repository lives. Never throws: a missing tool is
  /// [SecretScanUnavailable], anything else it cannot answer is a failure.
  Future<SecretScan> scanOutgoingSecrets(EnvironmentPath repo) async {
    try {
      final result = await runner.run(
        CommandRequest(
          executable: 'gitleaks',
          arguments: gitleaksOutgoingArguments(repo.path),
          timeout: mutationTimeout,
          removedEnvironment: kGitRemovedEnvironment,
        ),
      );
      return secretScanFrom(result);
    } on CommandException catch (error) {
      // ENOENT, and Windows' "cannot find the file", share code 2: the
      // executable is not there.
      final cause = error.cause;
      if (cause is ProcessException && cause.errorCode == 2) {
        return const SecretScanUnavailable();
      }
      return SecretScanFailed('$error');
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
          if (line.trim().isNotEmpty) unquoteGitPath(line.trim()),
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
  ///
  /// With [checkout] false the worktree is registered and its HEAD set, but no
  /// file is written: the populate is then [streamGit]'s `checkout --progress`,
  /// which is the only form that reports a percentage to a pipe.
  Future<GitWorktree> addWorktree(
    EnvironmentPath repo, {
    required EnvironmentPath worktreePath,
    required String branch,
    String? baseRef,
    bool checkout = true,
  }) async {
    final result = await _git(repo, [
      'worktree',
      'add',
      if (!checkout) '--no-checkout',
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

  /// Adds a worktree at [worktreePath] on local [branch], which already
  /// exists — `git worktree add <path> <branch>`, no `-b`. Git refuses a
  /// branch checked out in another worktree, in its own words.
  ///
  /// [checkout] as in [addWorktree].
  Future<GitWorktree> addWorktreeOnBranch(
    EnvironmentPath repo, {
    required EnvironmentPath worktreePath,
    required String branch,
    bool checkout = true,
  }) async {
    final result = await _git(repo, [
      'worktree',
      'add',
      if (!checkout) '--no-checkout',
      worktreePath.path,
      branch,
    ]);
    if (!result.ok) {
      throw GitException('git worktree add failed: ${result.stderr.trim()}');
    }
    return GitWorktree(path: worktreePath, branch: branch);
  }

  /// The local and remote-tracking branches of [repo], the most recently
  /// committed to first; the one checked out is [GitBranchRef.isCurrent].
  /// Where each is checked out is not git's `for-each-ref` to say on every
  /// version — `WorktreeService.branches` joins that from the worktree list.
  Future<List<GitBranchRef>> listBranches(EnvironmentPath repo) async {
    final result = await _git(repo, [
      'for-each-ref',
      '--sort=-committerdate',
      '--format=$kBranchRefFormat',
      'refs/heads',
      'refs/remotes',
    ]);
    if (!result.ok) {
      throw GitException('git for-each-ref failed: ${result.stderr.trim()}');
    }
    return parseBranchRefs(result.stdout);
  }

  /// Runs `git -C [directory] [args]` as a stream, handing each output line to
  /// [onLine]. git ends progress lines with `\r`, which the line splitter reads
  /// as a line end, so every percentage arrives on its own.
  ///
  /// Completing [cancel] kills the process and throws [GitCancelled]. Silence
  /// for [idleTimeout] — a credential prompt nobody can see — kills it and is
  /// reported as [GitStreamResult.stalled]; a command still printing progress
  /// is never cut off by a wall clock.
  Future<GitStreamResult> streamGit(
    EnvironmentPath directory,
    List<String> args, {
    void Function(String line)? onLine,
    Future<void>? cancel,
    Duration idleTimeout = const Duration(minutes: 5),
  }) async {
    final handle = await runner.start(
      CommandRequest(
        executable: 'git',
        arguments: ['-C', directory.path, ...args],
        environment: gitEnvironmentFor(args),
        removedEnvironment: kGitRemovedEnvironment,
      ),
    );
    final tail = OutputTail();
    var finished = false;
    var cancelled = false;
    var stalled = false;
    Timer? idle;
    void armIdle() {
      idle?.cancel();
      idle = Timer(idleTimeout, () {
        if (finished) return;
        stalled = true;
        handle.kill();
      });
    }

    void line(String text) {
      tail.add(text);
      onLine?.call(text);
      armIdle();
    }

    final outDone = Completer<void>();
    final errDone = Completer<void>();
    handle.stdoutLines.listen(
      line,
      onError: (Object _) {},
      onDone: outDone.complete,
    );
    handle.stderrLines.listen(
      line,
      onError: (Object _) {},
      onDone: errDone.complete,
    );
    unawaited(
      cancel?.then((_) {
        if (finished) return;
        cancelled = true;
        handle.kill();
      }),
    );
    armIdle();

    final code = await handle.exitCode;
    finished = true;
    idle?.cancel();
    // The last lines — usually the error — can trail the exit; not forever.
    await Future.wait([
      outDone.future,
      errDone.future,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    if (cancelled) throw GitCancelled(tail.lines);
    return GitStreamResult(
      exitCode: code,
      outputTail: tail.lines,
      stalled: stalled,
    );
  }

  /// Whether [worktree] declares submodules — a tracked `.gitmodules`.
  Future<bool> hasSubmodules(EnvironmentPath worktree) async {
    final result = await _git(worktree, ['ls-files', '--', '.gitmodules']);
    return result.ok && result.stdout.trim().isNotEmpty;
  }

  /// The names of [repo]'s remotes; empty when it has none or git refused.
  Future<List<String>> remoteNames(EnvironmentPath repo) async {
    final result = await _git(repo, ['remote']);
    if (!result.ok) return const [];
    return [
      for (final line in result.stdout.split(RegExp(r'[\r\n]')))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  /// [repo]'s remotes, each name to its fetch URL; empty when it has none or
  /// git refused.
  Future<Map<String, String>> remoteUrls(EnvironmentPath repo) async {
    final result = await _git(repo, ['remote', '-v']);
    if (!result.ok) return const {};
    final line = RegExp(r'^(\S+)\s+(.+?)\s+\(fetch\)\s*$');
    return {
      for (final text in result.stdout.split(RegExp(r'[\r\n]')))
        if (line.firstMatch(text.trim()) case final match?)
          match[1]!: match[2]!,
    };
  }

  /// Deletes local [branch] whatever it holds (`branch -D`). Only for a branch
  /// this app has just created and nothing has committed to.
  Future<void> deleteBranch(EnvironmentPath repo, String branch) async {
    final result = await _git(repo, ['branch', '-D', branch]);
    if (!result.ok) {
      throw GitException('git branch -D failed: ${result.stderr.trim()}');
    }
  }

  /// Forgets worktrees whose directories are gone (`worktree prune`).
  Future<void> pruneWorktrees(EnvironmentPath repo) async {
    final result = await _git(repo, ['worktree', 'prune']);
    if (!result.ok) {
      throw GitException('git worktree prune failed: ${result.stderr.trim()}');
    }
  }

  /// What a working tree holds beyond its commits, from one
  /// `git status --porcelain=v1 --ignored`. Throws [GitException] when git
  /// refused: "could not read" must never be mistaken for "clean".
  Future<WorktreeContents> contents(EnvironmentPath worktree) async {
    final result = await _git(worktree, [
      'status',
      '--porcelain=v1',
      '--ignored',
    ]);
    if (!result.ok) {
      throw GitException('git status failed: ${result.stderr.trim()}');
    }
    return parseWorktreeContents(result.stdout);
  }

  /// The newest [limit] entries of [ref]'s reflog in [repo], newest first.
  /// Empty when git keeps none; null when git could not be asked.
  Future<List<ReflogEntry>?> reflog(
    EnvironmentPath repo,
    String ref, {
    int limit = 50,
  }) async {
    try {
      final result = await _git(repo, [
        'reflog',
        'show',
        '--date=unix',
        '--format=%gd%x09%gs',
        '-n',
        '$limit',
        ref,
        '--',
      ]);
      if (!result.ok) return null;
      return parseReflog(result.stdout);
    } on CommandException {
      return null;
    }
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

  /// The files of [tree] at or under [paths], as git names them.
  Future<List<String>> filesInTree(
    EnvironmentPath repo,
    String tree, {
    required List<String> paths,
  }) async {
    // Quoted, not `-z`: the octal escapes are ASCII, so a non-ASCII name
    // survives however the runner decodes git's output.
    final result = await _git(repo, [
      '-c',
      'core.quotePath=true',
      'ls-tree',
      '-r',
      '--name-only',
      tree,
      '--',
      ...paths,
    ]);
    if (!result.ok) {
      throw GitException('git ls-tree failed: ${result.stderr.trim()}');
    }
    return [
      for (final line in result.stdout.split(RegExp(r'\r?\n')))
        if (line.isNotEmpty) unquoteGitPath(line),
    ];
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

  /// Lines added and removed per file between two objects, keyed by path. Empty
  /// when git cannot say: a count is withheld, never invented.
  Future<Map<String, FileDiffStat>> diffNumstat(
    EnvironmentPath repo, {
    required String from,
    String? to,
  }) async {
    try {
      final result = await _git(repo, [
        'diff',
        '--numstat',
        '--no-renames',
        from,
        ?to,
      ]);
      if (!result.ok) return const {};
      return parseNumstatByFile(result.stdout);
    } on CommandException {
      return const {};
    }
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
