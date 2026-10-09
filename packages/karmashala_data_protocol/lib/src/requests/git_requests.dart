part of '../data_request.dart';

// Git, worktrees, worktree cleanup and GitHub, done by the server (slice 3b).
// Every one runs `git`, `gh` or a file read where the checkout lives, so every
// one is answered when its work is done (`DataSession.handleLater`); what a
// write changed is told to every client as `CheckoutTouched`. A checkout is
// named as a [CheckoutRef]: a recorded one by id, or a directory spelled the
// way its own environment spells it.
//
// Refusals carry git's trouble: `notFound` is "not a git repository",
// `unavailable` is an environment that did not answer, `failed` is git's (or
// `gh`'s) own words.

DataRequest<Object?>? _gitRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      GitStatusOf.name => GitStatusOf(args._checkout()),
      GitChangesOf.name => GitChangesOf(args._checkout()),
      GitFileDiffStats.name => GitFileDiffStats(args._checkout()),
      GitDiff.name => GitDiff(
        args._checkout(),
        path: args.optionalString('path'),
        staged: args.boolean('staged', orElse: false),
        base: args.optionalString('base'),
      ),
      GitDiffUntracked.name => GitDiffUntracked(
        args._checkout(),
        args.string('path'),
      ),
      GitLog.name => GitLog(args._checkout(), limit: args.integer('limit')),
      GitBranch.name => GitBranch(args._checkout()),
      GitBranches.name => GitBranches(args._checkout()),
      GitHead.name => GitHead(args._checkout()),
      GitRevParse.name => GitRevParse(args._checkout(), args.string('rev')),
      GitAheadBehind.name => GitAheadBehind(
        args._checkout(),
        base: args.string('base'),
      ),
      GitRemoteBranchesContaining.name => GitRemoteBranchesContaining(
        args._checkout(),
        args.string('rev'),
      ),
      GitOriginFacts.name => GitOriginFacts(args._checkout()),
      GitMergeInProgress.name => GitMergeInProgress(args._checkout()),
      GitBlobShas.name => GitBlobShas(args._checkout(), args.strings('paths')),
      GitCodeFreshness.name => GitCodeFreshness(
        CodeIdentity.fromJson(args.values['identity']),
      ),
      GitPresenceOf.name => GitPresenceOf(
        args.objects('checkouts', environmentPathFromJson),
      ),
      GitDelivery.name => GitDelivery(
        args._checkout(),
        repository: args.values['repository'] == null
            ? null
            : args.value('repository', environmentPathFromJson),
      ),
      GitStage.name => GitStage(args._checkout(), args.strings('paths')),
      GitUnstage.name => GitUnstage(args._checkout(), args.strings('paths')),
      GitDiscard.name => GitDiscard(
        args._checkout(),
        tracked: args.strings('tracked', orEmpty: true),
        untracked: args.strings('untracked', orEmpty: true),
      ),
      GitCommitStaged.name => GitCommitStaged(
        args._checkout(),
        args.string('message'),
        all: args.boolean('all', orElse: false),
      ),
      GitFetch.name => GitFetch(args._checkout()),
      GitPull.name => GitPull(
        args._checkout(),
        rebase: args.boolean('rebase', orElse: false),
        merge: args.boolean('merge', orElse: false),
      ),
      GitPush.name => GitPush(
        args._checkout(),
        remote: args.optionalString('remote'),
        branch: args.optionalString('branch'),
      ),
      GitMerge.name => GitMerge(
        args._checkout(),
        args.string('ref'),
        commit: args.boolean('commit', orElse: false),
      ),
      GitAbortMerge.name => GitAbortMerge(args._checkout()),
      GitMoveBranch.name => GitMoveBranch(
        args._checkout(),
        branch: args.string('branch'),
        sha: args.string('sha'),
      ),
      WorktreesOf.name => WorktreesOf(args._checkout()),
      WorktreeLabels.name => WorktreeLabels(args.strings('repositoryIds')),
      WorktreeCreate.name => WorktreeCreate(
        args._checkout(),
        creationId: args.string('creationId'),
        worktreeName: args.string('name'),
        branch: args.string('branch'),
        baseRef: args.optionalString('baseRef'),
        launchesAgent: args.boolean('launchesAgent', orElse: false),
      ),
      WorktreeCreationCancel.name => WorktreeCreationCancel(
        args.string('creationId'),
      ),
      WorktreeAgentSettled.name => WorktreeAgentSettled(
        args.string('creationId'),
        error: args.optionalString('error'),
      ),
      WorktreeRemove.name => WorktreeRemove(
        args._checkout(),
        worktree: args.value('worktree', environmentPathFromJson),
        force: args.boolean('force', orElse: false),
      ),
      WorktreeCleanupPreview.name => const WorktreeCleanupPreview(),
      WorktreeCleanupSweep.name => const WorktreeCleanupSweep(),
      WorktreeCleanupLogRead.name => const WorktreeCleanupLogRead(),
      ProjectFoldersCreate.name => ProjectFoldersCreate(
        projectName: args.string('name'),
        root: args.value('root', environmentPathFromJson),
        gitUrl: args.optionalString('gitUrl'),
        workspaceId: args.optionalString('workspaceId'),
        createFolder: args.boolean('createFolder', orElse: false),
        initGit: args.boolean('initGit', orElse: false),
        scan: args.boolean('scan', orElse: true),
      ),
      ProjectRescan.name => ProjectRescan(args.string('projectId')),
      ScratchCheckoutCreate.name => ScratchCheckoutCreate(
        environmentId: args.string('environmentId'),
        hint: args.optionalString('hint'),
      ),
      ProjectMove.name => ProjectMove(
        args.string('projectId'),
        projectName: args.optionalString('name'),
        root: args.values['root'] == null
            ? null
            : args.value('root', environmentPathFromJson),
        defaultRepositoryId: args.optionalString('defaultRepositoryId'),
        clearDefaultRepository: args.boolean(
          'clearDefaultRepository',
          orElse: false,
        ),
      ),
      GitHubOverviewOf.name => GitHubOverviewOf(args._checkout()),
      GitHubPullRequest.name => GitHubPullRequest(
        args._checkout(),
        branch: args.string('branch'),
      ),
      GitHubMarkReady.name => GitHubMarkReady(
        args._checkout(),
        number: args.integer('number'),
      ),
      GitHubCreatePr.name => GitHubCreatePr(
        args._checkout(),
        title: args.string('title'),
        body: args.optionalString('body') ?? '',
      ),
      GitHubRuns.name => GitHubRuns(
        args._checkout(),
        branch: args.optionalString('branch'),
        limit: args.optionalInt('limit') ?? 10,
      ),
      GitHubRunLog.name => GitHubRunLog(
        args._checkout(),
        runId: args.integer('runId'),
      ),
      _ => null,
    };

extension on _Arguments {
  CheckoutRef _checkout() => value('checkout', CheckoutRef.fromJson);
}

/// Git, worktrees and GitHub, done by the server where the checkout lives;
/// answered when done.
sealed class GitWorkRequest<R> extends DataRequest<R> {
  const GitWorkRequest();
}

/// A request about one checkout.
sealed class CheckoutRequest<R> extends GitWorkRequest<R> {
  const CheckoutRequest(this.checkout);

  final CheckoutRef checkout;

  Map<String, Object?> get _checkoutJson => {'checkout': checkout.toJson()};

  @override
  Map<String, Object?> argumentsToJson() => _checkoutJson;
}

/// A write to a checkout, answered with nothing more; told as
/// `CheckoutTouched`.
sealed class _CheckoutAck extends CheckoutRequest<DataAck> {
  const _CheckoutAck(super.checkout);

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

sealed class _CheckoutString extends CheckoutRequest<String> {
  const _CheckoutString(super.checkout);

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}

sealed class _CheckoutMaybeString extends CheckoutRequest<String?> {
  const _CheckoutMaybeString(super.checkout);

  @override
  Object? resultToJson(String? result) => result;

  @override
  String? resultFromJson(Object? json) =>
      json == null || json is String ? json as String? : _badAnswer(kind);
}

// Reads.

/// The branch, its upstream, their divergence and the changed files — one
/// `git status --porcelain=v2 --branch`.
final class GitStatusOf extends CheckoutRequest<WorkingTreeStatus> {
  const GitStatusOf(super.checkout);

  static const String name = 'git.status';

  @override
  String get kind => name;

  @override
  Object? resultToJson(WorkingTreeStatus result) =>
      workingTreeStatusToJson(result);

  @override
  WorkingTreeStatus resultFromJson(Object? json) =>
      _decode(kind, () => workingTreeStatusFromJson(_object(json, kind)));
}

/// The changed files.
final class GitChangesOf extends CheckoutRequest<List<FileChange>> {
  const GitChangesOf(super.checkout);

  static const String name = 'git.changes';

  @override
  String get kind => name;

  @override
  Object? resultToJson(List<FileChange> result) => [
    for (final change in result) fileChangeToJson(change),
  ];

  @override
  List<FileChange> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) fileChangeFromJson(item)],
  );
}

/// Lines added and removed per file, one `git diff --numstat` for the whole
/// listing. A path git never mentioned — an untracked one — is absent.
final class GitFileDiffStats
    extends CheckoutRequest<Map<String, FileDiffStat>> {
  const GitFileDiffStats(super.checkout);

  static const String name = 'git.fileDiffStats';

  @override
  String get kind => name;

  @override
  Object? resultToJson(Map<String, FileDiffStat> result) => {
    for (final entry in result.entries)
      entry.key: fileDiffStatToJson(entry.value),
  };

  @override
  Map<String, FileDiffStat> resultFromJson(Object? json) => _decode(kind, () {
    return {
      for (final entry in _object(json, kind).entries)
        entry.key: fileDiffStatFromJson(_object(entry.value, kind)),
    };
  });
}

/// A unified diff, of [path] alone when given, of what is [staged] when
/// asked, against [base] when given (`HEAD` is staged and unstaged together).
final class GitDiff extends _CheckoutString {
  const GitDiff(super.checkout, {this.path, this.staged = false, this.base});

  static const String name = 'git.diff';

  final String? path;
  final bool staged;
  final String? base;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'path': ?path,
    'staged': staged,
    'base': ?base,
  };
}

/// An untracked [path] drawn as all added — empty when git tracks it, so a
/// tracked file with no changes is never drawn whole.
final class GitDiffUntracked extends _CheckoutString {
  const GitDiffUntracked(super.checkout, this.path);

  static const String name = 'git.diffUntracked';

  final String path;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'path': path};
}

/// The newest [limit] commits on the branch checked out.
final class GitLog extends CheckoutRequest<List<GitCommit>> {
  const GitLog(super.checkout, {this.limit = 20});

  static const String name = 'git.log';

  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'limit': limit};

  @override
  Object? resultToJson(List<GitCommit> result) => [
    for (final commit in result) gitCommitToJson(commit),
  ];

  @override
  List<GitCommit> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) gitCommitFromJson(item)],
  );
}

/// The branch checked out; null when detached.
final class GitBranch extends _CheckoutMaybeString {
  const GitBranch(super.checkout);

  static const String name = 'git.branch';

  @override
  String get kind => name;
}

/// Every local and remote-tracking branch, the most recently committed to
/// first: the one checked out marked, each local one naming the worktree it
/// is checked out in. What a new worktree's base, or the existing branch it
/// checks out, is picked from. A server that predates it refuses the kind, and
/// a client falls back to the branches its worktree listing names.
final class GitBranches extends CheckoutRequest<List<GitBranchRef>> {
  const GitBranches(super.checkout);

  static const String name = 'git.branches';

  @override
  String get kind => name;

  @override
  Object? resultToJson(List<GitBranchRef> result) => [
    for (final branch in result) gitBranchRefToJson(branch),
  ];

  @override
  List<GitBranchRef> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) gitBranchRefFromJson(item)],
  );
}

/// What the checkout's `HEAD` file names — its branch, or a short sha when
/// detached — read from the file at the server, no git; null when no `.git`
/// on the server's own filesystem answers.
final class GitHead extends _CheckoutMaybeString {
  const GitHead(super.checkout);

  static const String name = 'git.head';

  @override
  String get kind => name;
}

/// What [rev] resolves to, or null when it names nothing — asking for
/// `refs/heads/<name>` is how "does this branch exist" is asked.
final class GitRevParse extends _CheckoutMaybeString {
  const GitRevParse(super.checkout, this.rev);

  static const String name = 'git.revParse';

  final String rev;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'rev': rev};
}

/// How the checkout stands against [base] both ways; null when git could not
/// say.
final class GitAheadBehind extends CheckoutRequest<AheadBehind?> {
  const GitAheadBehind(super.checkout, {required this.base});

  static const String name = 'git.aheadBehind';

  final String base;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'base': base};

  @override
  Object? resultToJson(AheadBehind? result) =>
      result == null ? null : aheadBehindToJson(result);

  @override
  AheadBehind? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => aheadBehindFromJson(_object(json, kind)));
}

/// The remote-tracking branches holding [rev]; null when git could not say,
/// empty when nothing outside this machine has it.
final class GitRemoteBranchesContaining extends CheckoutRequest<List<String>?> {
  const GitRemoteBranchesContaining(super.checkout, this.rev);

  static const String name = 'git.remoteBranchesContaining';

  final String rev;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'rev': rev};

  @override
  Object? resultToJson(List<String>? result) => result;

  @override
  List<String>? resultFromJson(Object? json) => switch (json) {
    null => null,
    final List<Object?> list when list.every((i) => i is String) =>
      list.cast<String>(),
    _ => _badAnswer(kind),
  };
}

/// What the clone records about `origin`: its URL and default branch.
final class GitOriginFacts extends CheckoutRequest<RepositoryOrigin> {
  const GitOriginFacts(super.checkout);

  static const String name = 'git.originFacts';

  @override
  String get kind => name;

  @override
  Object? resultToJson(RepositoryOrigin result) =>
      repositoryOriginToJson(result);

  @override
  RepositoryOrigin resultFromJson(Object? json) =>
      _decode(kind, () => repositoryOriginFromJson(_object(json, kind)));
}

/// Whether a merge is half done; null when that filesystem cannot be seen.
final class GitMergeInProgress extends CheckoutRequest<bool?> {
  const GitMergeInProgress(super.checkout);

  static const String name = 'git.mergeInProgress';

  @override
  String get kind => name;

  @override
  Object? resultToJson(bool? result) => result;

  @override
  bool? resultFromJson(Object? json) =>
      json == null || json is bool ? json as bool? : _badAnswer(kind);
}

/// The content fingerprint of each of [paths] as it stands on disk; a path
/// git could not hash is absent — "cannot tell", never "unchanged".
final class GitBlobShas extends CheckoutRequest<Map<String, String>> {
  const GitBlobShas(super.checkout, this.paths);

  static const String name = 'git.blobShas';

  final List<String> paths;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'paths': paths};

  @override
  Object? resultToJson(Map<String, String> result) => result;

  @override
  Map<String, String> resultFromJson(Object? json) => _decode(
    kind,
    () => _object(json, kind).map((k, v) => MapEntry(k, v! as String)),
  );
}

/// Whether each of [checkouts] is under git, from the filesystem alone — in
/// the order asked. One request for everything a pane shows.
final class GitPresenceOf extends GitWorkRequest<List<GitPresence>> {
  const GitPresenceOf(this.checkouts);

  static const String name = 'git.presence';

  final List<EnvironmentPath> checkouts;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'checkouts': [for (final c in checkouts) environmentPathToJson(c)],
  };

  @override
  Object? resultToJson(List<GitPresence> result) => [
    for (final presence in result) presence.name,
  ];

  @override
  List<GitPresence> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final name in json! as List)
        GitPresence.values.byName(name as String),
    ];
  });
}

/// The **local** half of where a checkout's work stands — the branch, its
/// base, upstream and remote, dirty files, lines and commits against the
/// base. No `gh`. A worktree names the [repository] it came from: it is
/// measured against that clone's default branch, else its checked-out one.
final class GitDelivery extends CheckoutRequest<SessionDelivery> {
  const GitDelivery(super.checkout, {this.repository});

  static const String name = 'git.delivery';

  final EnvironmentPath? repository;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    if (repository case final repo?) 'repository': environmentPathToJson(repo),
  };

  @override
  Object? resultToJson(SessionDelivery result) => localDeliveryToJson(result);

  @override
  SessionDelivery resultFromJson(Object? json) =>
      _decode(kind, () => localDeliveryFromJson(_object(json, kind)));
}

// Writes.

/// Stages [paths], or everything when none are named.
final class GitStage extends _CheckoutAck {
  const GitStage(super.checkout, this.paths);

  static const String name = 'git.stage';

  final List<String> paths;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'paths': paths};
}

final class GitUnstage extends _CheckoutAck {
  const GitUnstage(super.checkout, this.paths);

  static const String name = 'git.unstage';

  final List<String> paths;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'paths': paths};
}

/// Throws the changes away: [tracked] paths are rewound, [untracked] ones
/// deleted — the second has no undo.
final class GitDiscard extends _CheckoutAck {
  const GitDiscard(
    super.checkout, {
    this.tracked = const [],
    this.untracked = const [],
  });

  static const String name = 'git.discard';

  final List<String> tracked;
  final List<String> untracked;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'tracked': tracked,
    'untracked': untracked,
  };
}

/// Commits what is staged — everything first, with [all]. Refused in git's
/// own sentence ("nothing to commit", a rejected hook).
final class GitCommitStaged extends _CheckoutAck {
  const GitCommitStaged(super.checkout, this.message, {this.all = false});

  static const String name = 'git.commit';

  final String message;
  final bool all;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'message': message,
    'all': all,
  };
}

final class GitFetch extends _CheckoutAck {
  const GitFetch(super.checkout);

  static const String name = 'git.fetch';

  @override
  String get kind => name;
}

/// Brings the upstream in: fast-forward only, unless [rebase] or [merge].
final class GitPull extends _CheckoutAck {
  const GitPull(super.checkout, {this.rebase = false, this.merge = false});

  static const String name = 'git.pull';

  final bool rebase;
  final bool merge;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'rebase': rebase,
    'merge': merge,
  };
}

/// Pushes the checked-out branch — [remote] and [branch] together publish a
/// branch with no upstream yet (`push -u`) — **after the server has scanned
/// what it would send for secrets**. A finding refuses it (`invalid`);
/// answered with how the scan went, in a sentence.
final class GitPush extends _CheckoutString {
  const GitPush(super.checkout, {this.remote, this.branch});

  static const String name = 'git.push';

  final String? remote;
  final String? branch;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'remote': ?remote,
    'branch': ?branch,
  };
}

/// Merges [ref] into the checked-out branch: fast-forwarding where it can,
/// or with [commit] always recording a merge commit.
final class GitMerge extends _CheckoutAck {
  const GitMerge(super.checkout, this.ref, {this.commit = false});

  static const String name = 'git.merge';

  final String ref;
  final bool commit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'ref': ref,
    'commit': commit,
  };
}

/// Undoes a merge that stopped; answers whether the tree came back clean.
final class GitAbortMerge extends CheckoutRequest<bool> {
  const GitAbortMerge(super.checkout);

  static const String name = 'git.abortMerge';

  @override
  String get kind => name;

  @override
  Object? resultToJson(bool result) => result;

  @override
  bool resultFromJson(Object? json) => json is bool ? json : _badAnswer(kind);
}

/// Moves [branch] back to [sha] (`update-ref`: no file moves).
final class GitMoveBranch extends _CheckoutAck {
  const GitMoveBranch(
    super.checkout, {
    required this.branch,
    required this.sha,
  });

  static const String name = 'git.moveBranch';

  final String branch;
  final String sha;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'branch': branch,
    'sha': sha,
  };
}

// Worktrees.

/// The worktrees of a checkout, the main one first.
final class WorktreesOf extends CheckoutRequest<List<GitWorktree>> {
  const WorktreesOf(super.checkout);

  static const String name = 'worktrees.of';

  @override
  String get kind => name;

  @override
  Object? resultToJson(List<GitWorktree> result) => [
    for (final worktree in result) gitWorktreeToJson(worktree),
  ];

  @override
  List<GitWorktree> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) gitWorktreeFromJson(item)],
  );
}

/// Worktree-or-not, branch and owner of each recorded checkout
/// [repositoryIds] — one `git worktree list` per repository family. A
/// checkout git could not answer for is absent.
final class WorktreeLabels extends GitWorkRequest<Map<String, CheckoutLabel>> {
  const WorktreeLabels(this.repositoryIds);

  static const String name = 'worktrees.labels';

  final List<String> repositoryIds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'repositoryIds': repositoryIds};

  @override
  Object? resultToJson(Map<String, CheckoutLabel> result) => {
    for (final entry in result.entries) entry.key: entry.value.toJson(),
  };

  @override
  Map<String, CheckoutLabel> resultFromJson(Object? json) => _decode(kind, () {
    return {
      for (final entry in _object(json, kind).entries)
        entry.key: CheckoutLabel.fromJson(_object(entry.value, kind)),
    };
  });
}

/// Makes a worktree [worktreeName] of the checkout on a new [branch] from [baseRef]
/// (the checkout's own HEAD when null), in stages — fetch, checkout,
/// submodules, the repository's setup, the agent — told as they move
/// (`WorktreeCreationChanged` under [creationId], the client's own id for it).
/// With [launchesAgent] the agent stage is left running for the asker to
/// settle ([WorktreeAgentSettled]).
final class WorktreeCreate extends CheckoutRequest<CreatedWorktree> {
  const WorktreeCreate(
    super.checkout, {
    required this.creationId,
    required this.worktreeName,
    required this.branch,
    this.baseRef,
    this.launchesAgent = false,
  });

  static const String name = 'worktrees.create';

  final String creationId;
  final String worktreeName;
  final String branch;
  final String? baseRef;
  final bool launchesAgent;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'creationId': creationId,
    'name': worktreeName,
    'branch': branch,
    'baseRef': ?baseRef,
    'launchesAgent': launchesAgent,
  };

  @override
  Object? resultToJson(CreatedWorktree result) => result.toJson();

  @override
  CreatedWorktree resultFromJson(Object? json) =>
      _decode(kind, () => CreatedWorktree.fromJson(_object(json, kind)));
}

/// Stops creation [creationId] while it still can be; the create is then
/// refused, saying what was cleaned up.
final class WorktreeCreationCancel extends GitWorkRequest<DataAck> {
  const WorktreeCreationCancel(this.creationId);

  static const String name = 'worktrees.cancel';

  final String creationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'creationId': creationId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// The agent a creation launched started ([error] null) or could not.
final class WorktreeAgentSettled extends GitWorkRequest<DataAck> {
  const WorktreeAgentSettled(this.creationId, {this.error});

  static const String name = 'worktrees.settleAgent';

  final String creationId;
  final String? error;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'creationId': creationId,
    'error': ?error,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Removes [worktree] of the checkout (its main worktree) — the repository's
/// teardown first. [force] only for a removal a person confirmed over
/// uncommitted changes. Answers what the teardown said, or null.
final class WorktreeRemove extends CheckoutRequest<String?> {
  const WorktreeRemove(
    super.checkout, {
    required this.worktree,
    this.force = false,
  });

  static const String name = 'worktrees.remove';

  final EnvironmentPath worktree;
  final bool force;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'worktree': environmentPathToJson(worktree),
    'force': force,
  };

  @override
  Object? resultToJson(String? result) => result;

  @override
  String? resultFromJson(Object? json) =>
      json == null || json is String ? json as String? : _badAnswer(kind);
}

// Worktree cleanup: the setting is a preference; the sweep, its schedule and
// its log are the server's.

sealed class _CleanupReport extends GitWorkRequest<WorktreeCleanupReport> {
  const _CleanupReport();

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(WorktreeCleanupReport result) => result.toJson();

  @override
  WorktreeCleanupReport resultFromJson(Object? json) =>
      _decode(kind, () => WorktreeCleanupReport.fromJson(_object(json, kind)));
}

/// What a sweep would do now, removing nothing — a default that is off is
/// judged as if on.
final class WorktreeCleanupPreview extends _CleanupReport {
  const WorktreeCleanupPreview();

  static const String name = 'worktreeCleanup.preview';

  @override
  String get kind => name;
}

/// Removes what the setting allows now — or joins the sweep already running.
final class WorktreeCleanupSweep extends _CleanupReport {
  const WorktreeCleanupSweep();

  static const String name = 'worktreeCleanup.sweep';

  @override
  String get kind => name;
}

/// The removal log and the last sweep.
final class WorktreeCleanupLogRead extends GitWorkRequest<WorktreeCleanupLog> {
  const WorktreeCleanupLogRead();

  static const String name = 'worktreeCleanup.log';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(WorktreeCleanupLog result) => result.toJson();

  @override
  WorktreeCleanupLog resultFromJson(Object? json) =>
      _decode(kind, () => WorktreeCleanupLog.fromJson(_object(json, kind)));
}

// A project's folders: cloning, finding the repositories under a root, and
// retiring the checkouts that are gone — where the folders are.

/// Creates project [projectName] at [root], cloning [gitUrl] there first when
/// given (an empty path in WSL or SSH clones into `~/karmashala/<repo>`),
/// with a checkout for every repository beneath it. Nothing is written when
/// the folder cannot be read. The new checkouts' CLI history is imported.
///
/// A server without [feature] ignores [createFolder], [initGit] and [scan].
final class ProjectFoldersCreate extends GitWorkRequest<ProjectCheckouts> {
  const ProjectFoldersCreate({
    required this.projectName,
    required this.root,
    this.gitUrl,
    this.workspaceId,
    this.createFolder = false,
    this.initGit = false,
    this.scan = true,
  });

  static const String name = 'projects.createFromFolder';

  /// In `welcome.features` when [createFolder], [initGit] and [scan] are
  /// served.
  static const String feature = 'projects.createFolder';

  final String projectName;
  final EnvironmentPath root;
  final String? gitUrl;
  final String? workspaceId;

  /// Makes a missing [root], with its parents, rather than refusing it.
  final bool createFolder;

  /// `git init` in a folder [createFolder] made; an existing one is left be.
  final bool initGit;

  /// Records every repository beneath [root]; without it, [root] alone.
  final bool scan;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'name': projectName,
    'root': environmentPathToJson(root),
    'gitUrl': ?gitUrl,
    'workspaceId': ?workspaceId,
    if (createFolder) 'createFolder': true,
    if (initGit) 'initGit': true,
    if (!scan) 'scan': false,
  };

  @override
  Object? resultToJson(ProjectCheckouts result) => result.toJson();

  @override
  ProjectCheckouts resultFromJson(Object? json) =>
      _decode(kind, () => ProjectCheckouts.fromJson(_object(json, kind)));
}

/// A folder for a session without a project: made under the Scratch project
/// of [environmentId] (`~/karmashala/scratch`, created with the project the
/// first time), named by the day, the first words of [hint] and a short id,
/// `git init`ed so checkpoints work, and recorded as a checkout. Answers that
/// checkout, which the launch then runs in.
final class ScratchCheckoutCreate extends GitWorkRequest<Repository> {
  const ScratchCheckoutCreate({required this.environmentId, this.hint});

  static const String name = 'projects.createScratchCheckout';

  final String environmentId;

  /// Words for the folder's name — the opening prompt, or the title.
  final String? hint;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'hint': ?hint,
  };

  @override
  Object? resultToJson(Repository result) => repositoryToJson(result);

  @override
  Repository resultFromJson(Object? json) =>
      _decode(kind, () => repositoryFromJson(_object(json, kind)));
}

/// Scans project [projectId]'s root again and records the repositories it
/// did not have; answers those. Checkouts provably gone are retired after.
final class ProjectRescan extends GitWorkRequest<List<Repository>> {
  const ProjectRescan(this.projectId);

  static const String name = 'projects.rescan';

  final String projectId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'projectId': projectId};

  @override
  Object? resultToJson(List<Repository> result) => [
    for (final repository in result) repositoryToJson(repository),
  ];

  @override
  List<Repository> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final item in json! as List) repositoryFromJson(item)];
  });
}

/// Edits project [projectId] where a moved [root] must be scanned first: a
/// folder that cannot be read fails with nothing changed, and the checkouts
/// underneath are carried across.
final class ProjectMove extends GitWorkRequest<ProjectUpdated> {
  const ProjectMove(
    this.projectId, {
    this.projectName,
    this.root,
    this.defaultRepositoryId,
    this.clearDefaultRepository = false,
  });

  static const String name = 'projects.move';

  final String projectId;
  final String? projectName;
  final EnvironmentPath? root;
  final String? defaultRepositoryId;
  final bool clearDefaultRepository;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'projectId': projectId,
    'name': ?projectName,
    if (root case final root?) 'root': environmentPathToJson(root),
    'defaultRepositoryId': ?defaultRepositoryId,
    'clearDefaultRepository': clearDefaultRepository,
  };

  @override
  Object? resultToJson(ProjectUpdated result) => result.toJson();

  @override
  ProjectUpdated resultFromJson(Object? json) =>
      _decode(kind, () => ProjectUpdated.fromJson(_object(json, kind)));
}

// GitHub, through `gh` where the checkout lives.

/// The repository, its open pull requests and open issues.
final class GitHubOverviewOf extends CheckoutRequest<GitHubOverview> {
  const GitHubOverviewOf(super.checkout);

  static const String name = 'github.overview';

  @override
  String get kind => name;

  @override
  Object? resultToJson(GitHubOverview result) => result.toJson();

  @override
  GitHubOverview resultFromJson(Object? json) =>
      _decode(kind, () => GitHubOverview.fromJson(_object(json, kind)));
}

/// [branch]'s pull request and its checks, the merge settings and review
/// threads, and the base's protection when a merge reads `BLOCKED`. A `gh`
/// that could not tell reads as no pull request.
final class GitHubPullRequest extends CheckoutRequest<PullRequestReading> {
  const GitHubPullRequest(super.checkout, {required this.branch});

  static const String name = 'github.pullRequest';

  final String branch;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'branch': branch,
  };

  @override
  Object? resultToJson(PullRequestReading result) => result.toJson();

  @override
  PullRequestReading resultFromJson(Object? json) =>
      _decode(kind, () => PullRequestReading.fromJson(_object(json, kind)));
}

/// Takes pull request [number] out of draft.
final class GitHubMarkReady extends _CheckoutAck {
  const GitHubMarkReady(super.checkout, {required this.number});

  static const String name = 'github.markReady';

  final int number;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'number': number,
  };
}

/// Opens a pull request for the checked-out branch; answers its URL.
final class GitHubCreatePr extends _CheckoutString {
  const GitHubCreatePr(super.checkout, {required this.title, this.body = ''});

  static const String name = 'github.createPr';

  final String title;
  final String body;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'title': title,
    'body': body,
  };
}

/// The newest GitHub Actions runs, on [branch] when given.
final class GitHubRuns extends CheckoutRequest<List<WorkflowRun>> {
  const GitHubRuns(super.checkout, {this.branch, this.limit = 10});

  static const String name = 'github.runs';

  final String? branch;
  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'branch': ?branch,
    'limit': limit,
  };

  @override
  Object? resultToJson(List<WorkflowRun> result) => [
    for (final run in result) run.toJson(),
  ];

  @override
  List<WorkflowRun> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind)) ?WorkflowRun.fromJson(item),
    ],
  );
}

/// The failed steps' log of run [runId], bounded; read-only.
final class GitHubRunLog extends CheckoutRequest<WorkflowRunLog> {
  const GitHubRunLog(super.checkout, {required this.runId});

  static const String name = 'github.runLog';

  final int runId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {..._checkoutJson, 'runId': runId};

  @override
  Object? resultToJson(WorkflowRunLog result) => result.toJson();

  @override
  WorkflowRunLog resultFromJson(Object? json) =>
      _decode(kind, () => WorkflowRunLog.fromJson(_object(json, kind)));
}

/// A recorded [identity] held against its checkout as it is now: fresh,
/// stale or unknown. Null asks about a result that recorded none, and is
/// answered "version unknown" without touching git.
final class GitCodeFreshness extends CheckoutRequest<CodeFreshness> {
  GitCodeFreshness(this.identity)
    : super(
        CheckoutRef.at(
          EnvironmentPath(
            environmentId: identity?.environmentId ?? '',
            path: identity?.path ?? '',
          ),
        ),
      );

  static const String name = 'git.codeFreshness';

  final CodeIdentity? identity;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    ..._checkoutJson,
    'identity': identity?.toJson(),
  };

  @override
  Object? resultToJson(CodeFreshness result) => result.toJson();

  @override
  CodeFreshness resultFromJson(Object? json) =>
      CodeFreshness.fromJson(json) ?? _badAnswer(kind);
}
