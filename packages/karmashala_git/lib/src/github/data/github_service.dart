import 'dart:convert';

import 'package:agent_cli/process.dart';
import '../domain/branch_protection.dart';
import '../domain/github_repo.dart';
import '../domain/issue.dart';
import '../domain/merge_strategies.dart';
import '../domain/pull_request.dart';
import '../domain/pull_request_snapshot.dart';

/// Why `gh` itself could not answer, as opposed to GitHub or the repository
/// refusing. The two states need different words and different remedies, so
/// they are not one value.
enum GitHubCliRefusal {
  /// There is no `gh` in the environment the repository lives in.
  notInstalled,

  /// `gh` is there and holds no GitHub credentials — normal, and fixable in
  /// one command.
  notAuthenticated,
}

/// Raised when a `gh` invocation fails (e.g. not installed, not authenticated, or
/// not a GitHub repository). Carries gh's stderr for an actionable diagnostic.
class GitHubException implements Exception {
  GitHubException(this.message, {this.refusal, this.cause});
  final String message;

  /// Set only when `gh` itself was the reason; null when `gh` ran and GitHub
  /// or the repository answered no.
  final GitHubCliRefusal? refusal;

  final Object? cause;

  @override
  String toString() => 'GitHubException: $message';
}

/// Whether the far side's shell answered that there is no `gh` there.
///
/// WSL and SSH hand the executable name to a shell on the other machine, so a
/// missing `gh` arrives as exit 127 rather than as a failure to start a
/// process. 127 is POSIX's own code for it and `gh` never exits with it.
bool saysCommandNotFound(CommandResult result) =>
    result.exitCode == 127 &&
    '${result.stdout}\n${result.stderr}'.toLowerCase().contains('not found');

/// Whether `gh` said it has no GitHub credentials. Its own remedy line is the
/// marker: every unauthenticated path prints `gh auth login`, and a rejected
/// token answers 401.
bool mentionsNotAuthenticated(String text) {
  final lower = text.toLowerCase();
  return lower.contains('gh auth login') ||
      lower.contains('not logged into') ||
      lower.contains('authentication token') ||
      lower.contains('http 401') ||
      lower.contains('bad credentials');
}

/// The refusal for a `gh` that is not in [environment] at all.
///
/// It names the environment because Karmashala runs `gh` where the repository
/// lives: a `gh` on Windows cannot answer for a checkout inside WSL, and one
/// inside WSL cannot see a Windows checkout's files. A message that only says
/// "gh failed" sends its reader to the wrong machine.
String ghNotInstalledMessage(String environment, {EnvironmentKind? kind}) =>
    'The GitHub CLI (gh) is not installed in $environment, which is where '
    'this repository lives and where Karmashala runs gh. '
    '${_ghInstallHint(kind)}';

String _ghInstallHint(EnvironmentKind? kind) => switch (kind) {
  EnvironmentKind.windowsNative =>
    'Install it there — "winget install --id GitHub.cli", or '
        'https://cli.github.com — then try again.',
  null => 'Install it there (https://cli.github.com) and try again.',
  _ =>
    "Install it there with that machine's package manager "
        '(https://cli.github.com) and try again.',
};

/// The refusal for a `gh` that is installed in [environment] and signed in to
/// nothing. Named separately from [ghNotInstalledMessage] because the remedy
/// is one command rather than an install, and this is the common state.
String ghNotAuthenticatedMessage(String environment) =>
    'The GitHub CLI (gh) in $environment is not signed in to GitHub. '
    'Run "gh auth login" there, then try again.';

/// Parses `gh pr list --json number,title,state,author` output.
List<PullRequest> parseGhPullRequests(String json) {
  final decoded = _decodeList(json);
  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>)
        PullRequest(
          number: (item['number'] as num?)?.toInt() ?? 0,
          title: (item['title'] ?? '').toString(),
          state: (item['state'] ?? '').toString(),
          author: item['author'] is Map
              ? (item['author']['login'] as String?)
              : null,
          url: _stringOrNull(item['url']),
        ),
  ];
}

/// Parses `gh pr view --json …` output — one object, or nothing.
PullRequestSnapshot? parseGhPullRequestView(String json) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) return null;
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map<String, dynamic>) return null;
  final number = (decoded['number'] as num?)?.toInt();
  final state = PullRequestState.parse(_stringOrNull(decoded['state']));
  if (number == null || state == null) return null;
  return PullRequestSnapshot(
    number: number,
    state: state,
    title: (decoded['title'] ?? '').toString(),
    url: _stringOrNull(decoded['url']),
    isDraft: decoded['isDraft'] == true,
    mergeable: switch (_stringOrNull(decoded['mergeable'])?.toUpperCase()) {
      'MERGEABLE' => true,
      'CONFLICTING' => false,
      // GitHub computes mergeability lazily and answers UNKNOWN until it has.
      _ => null,
    },
    mergeStateStatus: MergeStateStatus.parse(
      _stringOrNull(decoded['mergeStateStatus']),
    ),
    reviewDecision: ReviewDecision.parse(
      _stringOrNull(decoded['reviewDecision']),
    ),
    checks: parseCheckRollup(decoded['statusCheckRollup']),
    headRefName: _stringOrNull(decoded['headRefName']),
    baseRefName: _stringOrNull(decoded['baseRefName']),
  );
}

/// Sorts a `statusCheckRollup` array into passed / failed / pending / skipped.
/// Two shapes arrive: `CheckRun` and the older `StatusContext`.
ChecksSummary parseCheckRollup(Object? rollup) {
  if (rollup is! List) return ChecksSummary.none;
  var passed = 0;
  var failed = 0;
  var pending = 0;
  var skipped = 0;

  for (final item in rollup) {
    if (item is! Map) continue;
    final status = _stringOrNull(item['status'])?.toUpperCase();
    final conclusion = _stringOrNull(item['conclusion'])?.toUpperCase();
    final state = _stringOrNull(item['state'])?.toUpperCase();

    if (status != null && status != 'COMPLETED') {
      pending++;
      continue;
    }
    switch (conclusion ?? state) {
      case 'SUCCESS':
        passed++;
      case 'SKIPPED' || 'NEUTRAL':
        skipped++;
      case 'PENDING' || 'EXPECTED' || 'QUEUED' || 'IN_PROGRESS' || 'WAITING':
        pending++;
      case null:
        // Completed with nothing to say about how. Counted as running rather
        // than green: claiming a pass we cannot see is the worse mistake.
        pending++;
      default:
        // FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED, STARTUP_FAILURE.
        failed++;
    }
  }
  return ChecksSummary(
    passed: passed,
    failed: failed,
    pending: pending,
    skipped: skipped,
  );
}

/// One pull request's review conversations and its repository's merge
/// settings — the two facts `gh pr view --json` cannot give the delivery strip.
typedef ForgePolicy = ({
  MergeStrategies strategies,

  /// Null when the query did not answer; see
  /// [PullRequestSnapshot.unresolvedReviewThreads].
  int? unresolvedReviewThreads,
});

/// Nothing asked, or nothing answered — the reading that changes no decision.
const ForgePolicy kUnknownForgePolicy = (
  strategies: MergeStrategies.unknown,
  unresolvedReviewThreads: null,
);

/// Both halves in one process: unresolved review threads are not in `gh pr
/// view`'s field set, and the merge settings live on the repository.
const String kForgePolicyQuery =
    r'query($owner:String!,$name:String!,$number:Int!){'
    r'repository(owner:$owner,name:$name){'
    r'mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed '
    r'pullRequest(number:$number){'
    r'reviewThreads(first:100){totalCount nodes{isResolved}}}}}';

/// Parses [kForgePolicyQuery]'s response. Every missing piece degrades to null
/// rather than a zero — a partial `data` beside `errors` is normal.
ForgePolicy parseForgePolicy(String json) {
  const empty = kUnknownForgePolicy;
  final trimmed = json.trim();
  if (trimmed.isEmpty) return empty;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return empty;
  }
  if (decoded is! Map) return empty;
  final repository = (decoded['data'] as Map?)?['repository'];
  if (repository is! Map) return empty;

  bool? flag(Object? value) => value is bool ? value : null;
  final strategies = MergeStrategies(
    mergeCommit: flag(repository['mergeCommitAllowed']),
    squash: flag(repository['squashMergeAllowed']),
    rebase: flag(repository['rebaseMergeAllowed']),
  );

  final threads = (repository['pullRequest'] as Map?)?['reviewThreads'];
  if (threads is! Map) {
    return (strategies: strategies, unresolvedReviewThreads: null);
  }
  final nodes = threads['nodes'];
  if (nodes is! List) {
    return (strategies: strategies, unresolvedReviewThreads: null);
  }
  var unresolved = 0;
  for (final node in nodes) {
    if (node is Map && node['isResolved'] == false) unresolved++;
  }
  // The page is 100 threads; the strip only asks whether the number is above
  // zero, and undercounting is the harmless direction.
  return (strategies: strategies, unresolvedReviewThreads: unresolved);
}

/// Parses one `/branches/{b}/protection` body. Every field is read positively:
/// "the body did not carry it" and "no review is required" are different.
BranchProtection parseBranchProtection(String json, {String? branch}) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) return BranchProtection.unknown;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return BranchProtection.unknown;
  }
  if (decoded is! Map) return BranchProtection.unknown;
  // An error body is not a set of rules. `gh api` prints the response even on
  // a failure, and GitHub's error shape carries `message` and no rule keys.
  if (decoded.containsKey('message') && !decoded.containsKey('url')) {
    return mentionsForbidden(trimmed)
        ? const BranchProtection(status: BranchProtectionRead.forbidden)
        : BranchProtection.unknown;
  }

  bool enabled(Object? node) => node is Map && node['enabled'] == true;

  final reviews = decoded['required_pull_request_reviews'];
  final checks = decoded['required_status_checks'];
  final contexts = checks is Map ? checks['contexts'] : null;
  return BranchProtection(
    status: BranchProtectionRead.read,
    branch: branch,
    requiredApprovals: reviews is Map
        ? (reviews['required_approving_review_count'] as num?)?.toInt()
        : null,
    requiresCodeOwnerReview:
        reviews is Map && reviews['require_code_owner_reviews'] == true,
    requiredChecks: [
      if (contexts is List)
        for (final context in contexts)
          if (context is String && context.isNotEmpty) context,
    ],
    requiresConversationResolution: enabled(
      decoded['required_conversation_resolution'],
    ),
    requiresSignatures: enabled(decoded['required_signatures']),
    requiresLinearHistory: enabled(decoded['required_linear_history']),
  );
}

/// Whether this failure was GitHub refusing the *reader*. Both streams are
/// searched: `gh api` prints the body on stdout and its own line on stderr.
bool mentionsForbidden(String text) =>
    text.contains('HTTP 403') || text.contains('"403"');

/// Whether `gh` said the branch simply has no pull request — a fact — rather
/// than failing for a reason that means we could not tell.
bool mentionsNoPullRequest(String stderr) =>
    stderr.toLowerCase().contains('no pull requests found');

String? _stringOrNull(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

/// Parses `gh issue list --json number,title,state` output.
List<Issue> parseGhIssues(String json) {
  final decoded = _decodeList(json);
  return [
    for (final item in decoded)
      if (item is Map<String, dynamic>)
        Issue(
          number: (item['number'] as num?)?.toInt() ?? 0,
          title: (item['title'] ?? '').toString(),
          state: (item['state'] ?? '').toString(),
        ),
  ];
}

/// Parses `gh repo view --json …` output (a single object).
GitHubRepo? parseGhRepo(String json) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) return null;
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map<String, dynamic>) return null;
  final desc = (decoded['description'] ?? '').toString();
  final defaultBranch = decoded['defaultBranchRef'] is Map
      ? (decoded['defaultBranchRef']['name'] as String?)
      : null;
  return GitHubRepo(
    nameWithOwner: (decoded['nameWithOwner'] ?? '').toString(),
    url: (decoded['url'] ?? '').toString(),
    isPrivate: decoded['isPrivate'] == true,
    stargazerCount: (decoded['stargazerCount'] as num?)?.toInt() ?? 0,
    description: desc.isEmpty ? null : desc,
    defaultBranch: defaultBranch,
  );
}

List<dynamic> _decodeList(String json) {
  final trimmed = json.trim();
  if (trimmed.isEmpty) return const [];
  final decoded = jsonDecode(trimmed);
  return decoded is List ? decoded : const [];
}

/// GitHub operations via the `gh` CLI, run through a [CommandRunner] with the
/// repo as the working directory — that is how `gh` identifies it.
class GitHubService {
  GitHubService(this.runner, {this.environment});

  final CommandRunner runner;

  /// The environment [runner] reaches, when the caller has the row. Only used
  /// to name it in a refusal; without it the runner's id is used instead.
  final ExecutionEnvironment? environment;

  /// Where `gh` was looked for, in the words the rest of the app names an
  /// environment with.
  String get whereGhRuns {
    final env = environment;
    return (env == null ? null : environmentLabel(env)) ??
        describeEnvironmentId(runner.environmentId);
  }

  /// One `gh` process, and the one place a `gh` that cannot answer at all is
  /// turned into words.
  ///
  /// A missing executable is a [CommandException], not an exit code, so every
  /// `result.ok` branch below is bypassed for it — which is why the raw
  /// exception used to reach the UI.
  Future<CommandResult> _gh(EnvironmentPath repo, List<String> args) async {
    final CommandResult result;
    try {
      result = await runner.run(
        CommandRequest(
          executable: 'gh',
          arguments: args,
          workingDirectory: repo,
        ),
      );
    } on CommandException catch (e) {
      throw GitHubException(
        ghNotInstalledMessage(whereGhRuns, kind: environment?.kind),
        refusal: GitHubCliRefusal.notInstalled,
        cause: e,
      );
    }
    if (saysCommandNotFound(result)) {
      throw GitHubException(
        ghNotInstalledMessage(whereGhRuns, kind: environment?.kind),
        refusal: GitHubCliRefusal.notInstalled,
      );
    }
    if (!result.ok &&
        mentionsNotAuthenticated('${result.stdout}\n${result.stderr}')) {
      throw GitHubException(
        ghNotAuthenticatedMessage(whereGhRuns),
        refusal: GitHubCliRefusal.notAuthenticated,
      );
    }
    return result;
  }

  /// Repository metadata for [repo] (name, description, visibility, stars,
  /// default branch). Returns `null` if `gh` reports no repository.
  Future<GitHubRepo?> getRepository(EnvironmentPath repo) async {
    final result = await _gh(repo, [
      'repo',
      'view',
      '--json',
      'nameWithOwner,description,url,isPrivate,stargazerCount,defaultBranchRef',
    ]);
    if (!result.ok) {
      throw GitHubException('gh repo view failed: ${result.stderr.trim()}');
    }
    return parseGhRepo(result.stdout);
  }

  /// Open pull requests for [repo].
  Future<List<PullRequest>> listPullRequests(
    EnvironmentPath repo, {
    int limit = 50,
  }) async {
    final result = await _gh(repo, [
      'pr',
      'list',
      '--json',
      'number,title,state,author,url',
      '--limit',
      '$limit',
    ]);
    if (!result.ok) {
      throw GitHubException('gh pr list failed: ${result.stderr.trim()}');
    }
    return parseGhPullRequests(result.stdout);
  }

  /// The pull request for [branch] with its checks in one process, or `null`
  /// when the branch definitely has none. A `gh` that could not answer throws.
  Future<PullRequestSnapshot?> pullRequestFor(
    EnvironmentPath repo, {
    required String branch,
  }) async {
    final result = await _gh(repo, [
      'pr',
      'view',
      branch,
      '--json',
      // `mergeStateStatus` and `baseRefName` ride along in a call already being
      // made; requesting `mergeable` is what triggers the same computation anyway.
      'number,title,state,url,isDraft,mergeable,mergeStateStatus,'
          'reviewDecision,statusCheckRollup,headRefName,baseRefName',
    ]);
    if (!result.ok) {
      if (mentionsNoPullRequest(result.stderr)) return null;
      throw GitHubException('gh pr view failed: ${result.stderr.trim()}');
    }
    return parseGhPullRequestView(result.stdout);
  }

  /// Open issues for [repo].
  Future<List<Issue>> listIssues(EnvironmentPath repo, {int limit = 50}) async {
    final result = await _gh(repo, [
      'issue',
      'list',
      '--json',
      'number,title,state',
      '--limit',
      '$limit',
    ]);
    if (!result.ok) {
      throw GitHubException('gh issue list failed: ${result.stderr.trim()}');
    }
    return parseGhIssues(result.stdout);
  }

  /// The repository's merge settings and open review conversations, in one `gh
  /// api graphql` call. Never throws for a policy reason — only a failed process.
  Future<ForgePolicy> forgePolicyFor(
    EnvironmentPath repo, {
    required int number,
  }) async {
    final result = await _gh(repo, [
      'api',
      'graphql',
      '-f',
      'query=$kForgePolicyQuery',
      '-F',
      'owner={owner}',
      '-F',
      'name={repo}',
      '-F',
      'number=$number',
    ]);
    // `gh api graphql` exits non-zero on a GraphQL error but still prints the
    // document, so the body is parsed either way.
    return parseForgePolicy(result.stdout);
  }

  /// The branch-protection rules on [branch], for naming what a `BLOCKED` merge
  /// waits on. Never throws for a policy reason: a 403 is the non-admin answer.
  Future<BranchProtection> branchProtectionFor(
    EnvironmentPath repo, {
    required String branch,
  }) async {
    final result = await _gh(repo, [
      'api',
      // `{owner}` and `{repo}` are gh's own placeholders, filled from the
      // working directory — repo-relative like every other call here.
      'repos/{owner}/{repo}/branches/$branch/protection',
    ]);
    if (!result.ok) {
      return mentionsForbidden('${result.stdout}\n${result.stderr}')
          ? BranchProtection.forbidden
          : BranchProtection.unknown;
    }
    return parseBranchProtection(result.stdout, branch: branch);
  }

  /// Takes a pull request out of draft (`gh pr ready`). The number is passed
  /// explicitly rather than inferred from whatever branch is checked out.
  Future<void> markPullRequestReady(
    EnvironmentPath repo, {
    required int number,
  }) async {
    final result = await _gh(repo, ['pr', 'ready', '$number']);
    if (!result.ok) {
      throw GitHubException('gh pr ready failed: ${result.stderr.trim()}');
    }
  }

  /// Creates a pull request and returns its URL (gh prints it to stdout).
  Future<String> createPullRequest(
    EnvironmentPath repo, {
    required String title,
    String body = '',
  }) async {
    final result = await _gh(repo, [
      'pr',
      'create',
      '--title',
      title,
      '--body',
      body,
    ]);
    if (!result.ok) {
      throw GitHubException('gh pr create failed: ${result.stderr.trim()}');
    }
    return result.stdout.trim();
  }
}
