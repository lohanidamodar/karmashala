import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_projects/karmashala_projects.dart'
    show environmentPathFromJson, environmentPathToJson;
import 'package:karmashala_session/delivery.dart';

// The wire shape of git, worktrees and GitHub (slice 3b): what a checkout
// holds, how it stands against its base and its remote, and what the forge
// says. Every reader throws [FormatException] on a value out of shape.

/// The checkout a git request is about: a recorded one ([repositoryId]), or
/// any directory in an environment ([directory]), spelled the way **that
/// environment** spells it — a client never translates a path.
final class CheckoutRef {
  const CheckoutRef.repository(String this.repositoryId) : directory = null;

  const CheckoutRef.at(EnvironmentPath this.directory) : repositoryId = null;

  final String? repositoryId;
  final EnvironmentPath? directory;

  Map<String, Object?> toJson() => switch (directory) {
    final at? => environmentPathToJson(at),
    null => {'repositoryId': repositoryId},
  };

  static CheckoutRef fromJson(Map<String, Object?> json) {
    final id = json['repositoryId'];
    if (id is String) return CheckoutRef.repository(id);
    return CheckoutRef.at(environmentPathFromJson(json));
  }

  @override
  bool operator ==(Object other) =>
      other is CheckoutRef &&
      other.repositoryId == repositoryId &&
      other.directory == directory;

  @override
  int get hashCode => Object.hash(repositoryId, directory);

  @override
  String toString() => 'CheckoutRef(${repositoryId ?? directory})';
}

/// Why a server touched a checkout — what a client re-reads on.
enum CheckoutTouchCause {
  /// The server wrote to it: a stage, a commit, a pull, a merge.
  gitWrite,

  /// An agent working in it ended a turn.
  turnEnded,

  /// A worktree of it was made or removed.
  worktree;

  static CheckoutTouchCause fromName(Object? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => gitWrite);
}

Map<String, Object?> fileChangeToJson(FileChange change) => {
  'path': change.path,
  'type': change.type.name,
  'staged': change.staged,
  'unstaged': change.unstaged,
  'originalPath': ?change.originalPath,
  'conflict': ?change.conflict?.name,
};

FileChange fileChangeFromJson(Map<String, Object?> json) => FileChange(
  path: json['path']! as String,
  type: FileChangeType.values.byName(json['type']! as String),
  staged: json['staged'] == true,
  unstaged: json['unstaged'] == true,
  originalPath: json['originalPath'] as String?,
  conflict: switch (json['conflict']) {
    final String name => MergeConflict.values.byName(name),
    _ => null,
  },
);

Map<String, Object?> workingTreeStatusToJson(WorkingTreeStatus status) => {
  'branch': ?status.branch,
  'upstream': ?status.upstream,
  'ahead': ?status.aheadOfUpstream,
  'behind': ?status.behindUpstream,
  'changes': [for (final c in status.changes) fileChangeToJson(c)],
};

WorkingTreeStatus workingTreeStatusFromJson(Map<String, Object?> json) =>
    WorkingTreeStatus(
      branch: json['branch'] as String?,
      upstream: json['upstream'] as String?,
      aheadOfUpstream: json['ahead'] as int?,
      behindUpstream: json['behind'] as int?,
      changes: [
        for (final item in _list(json['changes']))
          fileChangeFromJson(_map(item)),
      ],
    );

Map<String, Object?> fileDiffStatToJson(FileDiffStat stat) => {
  'added': stat.added,
  'removed': stat.removed,
};

FileDiffStat fileDiffStatFromJson(Map<String, Object?> json) => FileDiffStat(
  added: json['added'] as int?,
  removed: json['removed'] as int?,
);

Map<String, Object?> lineStatToJson(DiffStat stat) => {
  'added': stat.added,
  'removed': stat.removed,
  'files': stat.files,
  'binary': stat.binaryFiles,
};

DiffStat lineStatFromJson(Map<String, Object?> json) => DiffStat(
  added: json['added']! as int,
  removed: json['removed']! as int,
  files: json['files']! as int,
  binaryFiles: json['binary'] as int? ?? 0,
);

Map<String, Object?> aheadBehindToJson(AheadBehind value) => {
  'ahead': value.ahead,
  'behind': value.behind,
};

AheadBehind aheadBehindFromJson(Map<String, Object?> json) =>
    AheadBehind(ahead: json['ahead']! as int, behind: json['behind']! as int);

Map<String, Object?> gitCommitToJson(GitCommit commit) => {
  'sha': commit.sha,
  'author': commit.author,
  'subject': commit.subject,
};

GitCommit gitCommitFromJson(Map<String, Object?> json) => GitCommit(
  sha: json['sha']! as String,
  author: json['author']! as String,
  subject: json['subject']! as String,
);

Map<String, Object?> gitWorktreeToJson(GitWorktree worktree) => {
  'path': environmentPathToJson(worktree.path),
  'branch': ?worktree.branch,
  'head': ?worktree.head,
  if (worktree.isBare) 'bare': true,
};

GitWorktree gitWorktreeFromJson(Map<String, Object?> json) => GitWorktree(
  path: environmentPathFromJson(json['path']),
  branch: json['branch'] as String?,
  head: json['head'] as String?,
  isBare: json['bare'] == true,
);

Map<String, Object?> gitBranchRefToJson(GitBranchRef branch) => {
  'name': branch.name,
  'remote': ?branch.remote,
  if (branch.isCurrent) 'current': true,
  'upstream': ?branch.upstream,
  if (branch.worktree case final worktree?)
    'worktree': environmentPathToJson(worktree),
};

GitBranchRef gitBranchRefFromJson(Map<String, Object?> json) => GitBranchRef(
  name: json['name']! as String,
  remote: json['remote'] as String?,
  isCurrent: json['current'] == true,
  upstream: json['upstream'] as String?,
  worktree: json['worktree'] == null
      ? null
      : environmentPathFromJson(json['worktree']),
);

Map<String, Object?> repositoryOriginToJson(RepositoryOrigin origin) => {
  'url': ?origin.url,
  'head': ?origin.head,
};

RepositoryOrigin repositoryOriginFromJson(Map<String, Object?> json) =>
    RepositoryOrigin(
      url: json['url'] as String?,
      head: json['head'] as String?,
    );

/// The **local** half of where a checkout's work stands — no `gh`.
Map<String, Object?> localDeliveryToJson(SessionDelivery delivery) => {
  'branch': ?delivery.branch,
  'baseBranch': ?delivery.baseBranch,
  'upstream': ?delivery.upstream,
  'hasRemote': ?delivery.hasRemote,
  if (delivery.remote case final remote?)
    'remote': {'host': remote.host, 'slug': remote.slug},
  'defaultBranch': ?delivery.defaultBranch,
  'dirtyFiles': ?delivery.dirtyFiles,
  if (delivery.lines case final lines?) 'lines': lineStatToJson(lines),
  'aheadOfBase': ?delivery.aheadOfBase,
  'behindBase': ?delivery.behindBase,
  'unpushed': ?delivery.unpushed,
};

SessionDelivery localDeliveryFromJson(Map<String, Object?> json) =>
    SessionDelivery(
      branch: json['branch'] as String?,
      baseBranch: json['baseBranch'] as String?,
      upstream: json['upstream'] as String?,
      hasRemote: json['hasRemote'] as bool?,
      remote: switch (json['remote']) {
        final Map<Object?, Object?> remote => RemoteRepo(
          host: remote['host']! as String,
          slug: remote['slug']! as String,
        ),
        _ => null,
      },
      defaultBranch: json['defaultBranch'] as String?,
      dirtyFiles: json['dirtyFiles'] as int?,
      lines: switch (json['lines']) {
        final Map<Object?, Object?> lines => lineStatFromJson(
          lines.cast<String, Object?>(),
        ),
        _ => null,
      },
      aheadOfBase: json['aheadOfBase'] as int?,
      behindBase: json['behindBase'] as int?,
      unpushed: json['unpushed'] as int?,
    );

Map<String, Object?> pullRequestSnapshotToJson(PullRequestSnapshot pr) => {
  'number': pr.number,
  'state': pr.state.name,
  'title': pr.title,
  'url': ?pr.url,
  'isDraft': pr.isDraft,
  'mergeable': ?pr.mergeable,
  'mergeStateStatus': ?pr.mergeStateStatus?.name,
  'reviewDecision': ?pr.reviewDecision?.name,
  'unresolvedReviewThreads': ?pr.unresolvedReviewThreads,
  'checks': {
    'passed': pr.checks.passed,
    'failed': pr.checks.failed,
    'pending': pr.checks.pending,
    'skipped': pr.checks.skipped,
  },
  'headRefName': ?pr.headRefName,
  'baseRefName': ?pr.baseRefName,
};

PullRequestSnapshot pullRequestSnapshotFromJson(Map<String, Object?> json) {
  final checks = _map(json['checks']);
  return PullRequestSnapshot(
    number: json['number']! as int,
    state: PullRequestState.values.byName(json['state']! as String),
    title: json['title'] as String? ?? '',
    url: json['url'] as String?,
    isDraft: json['isDraft'] == true,
    mergeable: json['mergeable'] as bool?,
    mergeStateStatus: switch (json['mergeStateStatus']) {
      final String name => MergeStateStatus.values.byName(name),
      _ => null,
    },
    reviewDecision: switch (json['reviewDecision']) {
      final String name => ReviewDecision.values.byName(name),
      _ => null,
    },
    unresolvedReviewThreads: json['unresolvedReviewThreads'] as int?,
    checks: ChecksSummary(
      passed: checks['passed'] as int? ?? 0,
      failed: checks['failed'] as int? ?? 0,
      pending: checks['pending'] as int? ?? 0,
      skipped: checks['skipped'] as int? ?? 0,
    ),
    headRefName: json['headRefName'] as String?,
    baseRefName: json['baseRefName'] as String?,
  );
}

Map<String, Object?> branchProtectionToJson(BranchProtection p) => {
  'status': p.status.name,
  'branch': ?p.branch,
  'requiredApprovals': ?p.requiredApprovals,
  'codeOwners': p.requiresCodeOwnerReview,
  'checks': p.requiredChecks,
  'conversations': p.requiresConversationResolution,
  'signatures': p.requiresSignatures,
  'linear': p.requiresLinearHistory,
};

BranchProtection branchProtectionFromJson(Map<String, Object?> json) =>
    BranchProtection(
      status: BranchProtectionRead.values.byName(json['status']! as String),
      branch: json['branch'] as String?,
      requiredApprovals: json['requiredApprovals'] as int?,
      requiresCodeOwnerReview: json['codeOwners'] == true,
      requiredChecks: _strings(json['checks']),
      requiresConversationResolution: json['conversations'] == true,
      requiresSignatures: json['signatures'] == true,
      requiresLinearHistory: json['linear'] == true,
    );

/// What the forge says about one branch's pull request — the part of a
/// checkout's delivery that costs network: the pull request and its checks,
/// the repository's merge settings and open review threads, and (only when a
/// merge reads `BLOCKED`) the base branch's protection.
final class PullRequestReading {
  const PullRequestReading({
    this.pullRequest,
    this.strategies = MergeStrategies.unknown,
    this.protection = BranchProtection.unknown,
  });

  static const none = PullRequestReading();

  /// Null for no pull request — and for a `gh` that could not tell.
  final PullRequestSnapshot? pullRequest;
  final MergeStrategies strategies;
  final BranchProtection protection;

  Map<String, Object?> toJson() => {
    if (pullRequest case final pr?)
      'pullRequest': pullRequestSnapshotToJson(pr),
    'strategies': {
      'merge': ?strategies.mergeCommit,
      'squash': ?strategies.squash,
      'rebase': ?strategies.rebase,
    },
    'protection': branchProtectionToJson(protection),
  };

  static PullRequestReading fromJson(Map<String, Object?> json) {
    final strategies = _map(json['strategies']);
    return PullRequestReading(
      pullRequest: switch (json['pullRequest']) {
        final Map<Object?, Object?> pr => pullRequestSnapshotFromJson(
          pr.cast<String, Object?>(),
        ),
        _ => null,
      },
      strategies: MergeStrategies(
        mergeCommit: strategies['merge'] as bool?,
        squash: strategies['squash'] as bool?,
        rebase: strategies['rebase'] as bool?,
      ),
      protection: branchProtectionFromJson(_map(json['protection'])),
    );
  }
}

/// A repository's page on the forge: its metadata, open pull requests and
/// open issues — each read on its own, so one `gh` refusal (issues switched
/// off, a rate limit) does not blank the other two. A part that could not be
/// read says why in its `…Failure`, and its value is then empty.
final class GitHubOverview {
  const GitHubOverview({
    this.repository,
    this.pullRequests = const [],
    this.issues = const [],
    this.repositoryFailure,
    this.pullRequestsFailure,
    this.issuesFailure,
  });

  /// Null when `gh` knows no repository there.
  final GitHubRepo? repository;
  final List<PullRequest> pullRequests;
  final List<Issue> issues;

  /// Why [repository] could not be read, in `gh`'s or the server's words.
  final String? repositoryFailure;

  /// Why [pullRequests] could not be read.
  final String? pullRequestsFailure;

  /// Why [issues] could not be read.
  final String? issuesFailure;

  Map<String, Object?> toJson() => {
    'repositoryFailure': ?repositoryFailure,
    'pullRequestsFailure': ?pullRequestsFailure,
    'issuesFailure': ?issuesFailure,
    if (repository case final r?)
      'repository': {
        'nameWithOwner': r.nameWithOwner,
        'url': r.url,
        'isPrivate': r.isPrivate,
        'stars': r.stargazerCount,
        'description': ?r.description,
        'defaultBranch': ?r.defaultBranch,
      },
    'pullRequests': [
      for (final pr in pullRequests)
        {
          'number': pr.number,
          'title': pr.title,
          'state': pr.state,
          'author': ?pr.author,
          'url': ?pr.url,
        },
    ],
    'issues': [
      for (final issue in issues)
        {'number': issue.number, 'title': issue.title, 'state': issue.state},
    ],
  };

  static GitHubOverview fromJson(Map<String, Object?> json) => GitHubOverview(
    repositoryFailure: json['repositoryFailure'] as String?,
    pullRequestsFailure: json['pullRequestsFailure'] as String?,
    issuesFailure: json['issuesFailure'] as String?,
    repository: switch (json['repository']) {
      final Map<Object?, Object?> r => GitHubRepo(
        nameWithOwner: r['nameWithOwner']! as String,
        url: r['url']! as String,
        isPrivate: r['isPrivate'] == true,
        stargazerCount: r['stars'] as int? ?? 0,
        description: r['description'] as String?,
        defaultBranch: r['defaultBranch'] as String?,
      ),
      _ => null,
    },
    pullRequests: [
      for (final item in _list(json['pullRequests']))
        PullRequest(
          number: _map(item)['number']! as int,
          title: _map(item)['title']! as String,
          state: _map(item)['state']! as String,
          author: _map(item)['author'] as String?,
          url: _map(item)['url'] as String?,
        ),
    ],
    issues: [
      for (final item in _list(json['issues']))
        Issue(
          number: _map(item)['number']! as int,
          title: _map(item)['title']! as String,
          state: _map(item)['state']! as String,
        ),
    ],
  );
}

/// A worktree the server made, and the stage record of how.
final class CreatedWorktree {
  const CreatedWorktree({required this.worktree, required this.record});

  final GitWorktree worktree;
  final WorktreeCreationRecord record;

  Map<String, Object?> toJson() => {
    'worktree': gitWorktreeToJson(worktree),
    'record': record.toJson(),
  };

  static CreatedWorktree fromJson(Map<String, Object?> json) => CreatedWorktree(
    worktree: gitWorktreeFromJson(_map(json['worktree'])),
    record:
        WorktreeCreationRecord.fromJson(json['record']) ??
        (throw const FormatException('not a creation record')),
  );
}

Map<String, Object?> _map(Object? json) => json is Map
    ? json.cast<String, Object?>()
    : throw const FormatException('not an object');

List<Object?> _list(Object? json) => json is List ? json : const [];

List<String> _strings(Object? json) => [
  for (final item in _list(json))
    if (item is String) item,
];
