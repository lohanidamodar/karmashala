import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/github.dart';

/// Raised when a `gh` invocation fails (e.g. not installed, not authenticated, or
/// not a GitHub repository). Carries gh's stderr for an actionable diagnostic.
class GitHubException implements Exception {
  GitHubException(this.message);
  final String message;
  @override
  String toString() => 'GitHubException: $message';
}

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
///
/// Two shapes arrive in the same array: GitHub Actions and other apps report
/// `CheckRun` (a `status` plus, once complete, a `conclusion`), while older
/// integrations report `StatusContext` (a single `state`). Reading only one of
/// them would silently call a repository "no checks".
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

/// What one pull request's review conversations and its repository's merge
/// settings say — the two facts the delivery strip needs that `gh pr view
/// --json` cannot give it.
///
/// A record rather than a class because it is a return shape and nothing keeps
/// one: both halves are unpacked into [PullRequestSnapshot] and
/// `SessionDelivery` the moment they arrive.
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

/// The one query in this file that is not `gh <noun> <verb> --json`.
///
/// **Both halves come back in one process on purpose.** Unresolved review
/// threads are not in `gh pr view`'s field set at all (checked on 2026-09-02:
/// the nearest fields, `comments` and `reviews`, carry bodies with no
/// resolution flag), and the merge settings are on the repository rather than
/// the pull request, so they would otherwise be a `gh pr view` *plus* a `gh
/// repo view`. GraphQL will return a repository and one of its pull requests in
/// the same document, which turns two extra processes into one — and this call
/// is already the expensive half of the delivery poll.
///
/// `{owner}` and `{repo}` are `gh`'s own placeholders, filled from the working
/// directory, so this stays repo-relative like every other call here and needs
/// no parsing of the remote URL. Verified against `lohanidamodar/karmashala-app`
/// and `cli/cli` on 2026-09-02.
const String kForgePolicyQuery =
    r'query($owner:String!,$name:String!,$number:Int!){'
    r'repository(owner:$owner,name:$name){'
    r'mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed '
    r'pullRequest(number:$number){'
    r'reviewThreads(first:100){totalCount nodes{isResolved}}}}}';

/// Parses [kForgePolicyQuery]'s response.
///
/// **Every missing piece degrades to null rather than to a zero.** A GraphQL
/// response that carries `errors` alongside a partial `data` is normal — a
/// token that can read a repository's pull requests but not its settings gets
/// exactly that — and reading an absent `mergeCommitAllowed` as `false` would
/// disable a merge the repository actually allows. Likewise an absent
/// `reviewThreads` is "did not ask", not "nothing is open".
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
  // The page is 100 threads. A pull request with more than that has bigger
  // problems than this count's precision, and undercounting is the harmless
  // direction: the strip only asks whether the number is above zero, and the
  // unresolved threads on a conversation that long are not all on page two.
  return (strategies: strategies, unresolvedReviewThreads: unresolved);
}

/// Parses one `/branches/{b}/protection` body into the rules it names.
///
/// Every field is read positively: a missing `required_pull_request_reviews`
/// leaves [BranchProtection.requiredApprovals] null rather than zero, because
/// "the body did not carry it" and "no review is required" would send the
/// strip to name the wrong rule — or to stop naming the right one.
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

/// Whether this failure was GitHub refusing the *reader*, not the branch
/// having nothing to say.
///
/// `gh api` prints the response body on stdout and its own line on stderr, so
/// both are searched: `{"message":"Must have admin rights to Repository.",
/// "status":"403"}` and `gh: Must have admin rights to Repository. (HTTP 403)`.
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

/// GitHub operations via the `gh` CLI, executed through a [CommandRunner] in the
/// repository's environment. `gh` uses the working directory to identify the
/// repository, so commands are run with the repo as the working directory.
class GitHubService {
  GitHubService(this.runner);

  final CommandRunner runner;

  Future<CommandResult> _gh(EnvironmentPath repo, List<String> args) {
    return runner.run(
      CommandRequest(executable: 'gh', arguments: args, workingDirectory: repo),
    );
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

  /// The pull request for [branch] together with its checks, or `null` when
  /// the branch definitely has none.
  ///
  /// **One process for both.** `gh pr checks` would be a second invocation for
  /// data `statusCheckRollup` already carries, and the delivery strip draws the
  /// PR and its checks in the same row — so it asks once.
  ///
  /// The two failures are told apart deliberately: "no pull requests found" is
  /// a fact about the branch and returns `null`, while `gh` missing, logged
  /// out, or pointed at a non-GitHub remote throws, so a caller can keep saying
  /// "could not tell" instead of "there is no PR".
  Future<PullRequestSnapshot?> pullRequestFor(
    EnvironmentPath repo, {
    required String branch,
  }) async {
    final result = await _gh(repo, [
      'pr',
      'view',
      branch,
      '--json',
      // `mergeStateStatus` rides along in the call that was already being
      // made. It is the only field here that costs GitHub extra work — it is
      // computed lazily, the same computation behind `mergeable` — and asking
      // for it beside `mergeable` costs nothing more, because requesting
      // either one is what triggers the computation in the first place.
      // `baseRefName` rides along too: branch protection is a property of the
      // base, so naming a BLOCKED merge's rule needs it, and asking for it
      // here costs nothing over asking for the rest.
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

  /// The repository's merge settings and the pull request's open review
  /// conversations, in one `gh api graphql` call. See [kForgePolicyQuery].
  ///
  /// Never throws for a policy reason: a token without settings access, a
  /// GraphQL error, or a repository `gh` cannot resolve all come back as
  /// [MergeStrategies.unknown] with a null thread count, which is the reading
  /// that changes nothing about what the strip offers. Only a failed process
  /// throws, and the delivery provider already turns that into null.
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
    // document, so the body is parsed either way: a partial answer is worth
    // more than none, and a body that carries nothing usable degrades to
    // "could not tell" inside the parser.
    return parseForgePolicy(result.stdout);
  }

  /// The branch-protection rules on [branch], for naming what a `BLOCKED`
  /// merge is waiting on.
  ///
  /// **The third `gh` process, and the only one paid for by a reading rather
  /// than by a row.** `mergeStateStatus: BLOCKED` is the common state of every
  /// open pull request in a protected repository, so this is asked only once
  /// something has already read that status — see
  /// `checkoutMergeProtectionProvider`, which short-circuits before the
  /// process for every other state.
  ///
  /// **Never throws for a policy reason.** A 403 is the ordinary answer for a
  /// non-admin and comes back as [BranchProtectionRead.forbidden]; a 404 (the
  /// branch is guarded by a ruleset rather than by classic protection, or by
  /// nothing at all), a logged-out `gh` and an unparseable body all come back
  /// as [BranchProtection.unknown], which leaves the caller's own sentence
  /// exactly as it was.
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

  /// Takes a pull request out of draft (`gh pr ready`).
  ///
  /// **One of the app's own operations, not a prompt.** There is nothing here
  /// for a model to compose: it is a boolean on the forge, and the only way to
  /// get it wrong is to flip it on the wrong pull request — which is why the
  /// number is passed explicitly rather than left to `gh` to infer from
  /// whatever branch happens to be checked out.
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
