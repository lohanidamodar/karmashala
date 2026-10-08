import 'dart:convert';

import 'package:agent_cli/process.dart';
import '../../git/domain/remote_repo.dart';
import '../api/github_client.dart';
import '../api/github_credentials.dart';
import '../domain/branch_protection.dart';
import '../domain/github_repo.dart';
import '../domain/issue.dart';
import '../domain/merge_strategies.dart';
import '../domain/pull_request.dart';
import '../domain/pull_request_snapshot.dart';
import '../domain/workflow_run.dart';

/// Why GitHub could not be asked at all, as opposed to GitHub or the
/// repository refusing.
enum GitHubRefusal {
  /// No token Karmashala may use for the repository's host.
  noAccess,

  /// The checkout has no `origin`, or one that names no repository.
  noRemote,
}

/// Raised when a GitHub call fails: no access, no remote, or GitHub said no.
class GitHubException implements Exception {
  GitHubException(this.message, {this.refusal, this.status, this.cause});
  final String message;

  /// Set only when GitHub could not be asked; null when it answered no.
  final GitHubRefusal? refusal;

  /// GitHub's HTTP status, when it answered.
  final int? status;

  final Object? cause;

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

/// [branch]'s pull requests, newest first, with what the strip reads.
const String kPullRequestForBranchQuery =
    r'query($owner:String!,$name:String!,$branch:String!){'
    r'repository(owner:$owner,name:$name){'
    r'pullRequests(headRefName:$branch,first:10,'
    r'orderBy:{field:CREATED_AT,direction:DESC}){nodes{'
    r'number title state url isDraft mergeable mergeStateStatus '
    r'reviewDecision headRefName baseRefName '
    r'headRepositoryOwner{login} '
    r'commits(last:1){nodes{commit{statusCheckRollup{'
    r'contexts(first:100){nodes{__typename '
    r'... on CheckRun{status conclusion} '
    r'... on StatusContext{state}}}}}}}}}}}';

const String _markReadyMutation =
    r'mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id})'
    r'{pullRequest{isDraft}}}';

/// The pull request [kPullRequestForBranchQuery] answered for a branch, in
/// the shape [parseGhPullRequestView] reads: an open one from the
/// repository's own owner first, then the newest.
PullRequestSnapshot? pullRequestFromGraphql(
  Map<String, Object?> answer, {
  required String owner,
}) {
  final repository = (answer['data'] as Map?)?['repository'];
  final nodes = ((repository as Map?)?['pullRequests'] as Map?)?['nodes'];
  if (nodes is! List || nodes.isEmpty) return null;
  final candidates = nodes.whereType<Map>().toList();
  bool ours(Map node) =>
      ((node['headRepositoryOwner'] as Map?)?['login'] as String?)
          ?.toLowerCase() ==
      owner.toLowerCase();
  final chosen =
      candidates.where((n) => n['state'] == 'OPEN' && ours(n)).firstOrNull ??
      candidates.where((n) => n['state'] == 'OPEN').firstOrNull ??
      candidates.where(ours).firstOrNull ??
      candidates.firstOrNull;
  if (chosen == null) return null;
  final commits = (chosen['commits'] as Map?)?['nodes'];
  Object? at(Object? node, String key) => node is Map ? node[key] : null;
  final last = commits is List && commits.isNotEmpty ? commits.last : null;
  final rollup = at(
    at(at(at(last, 'commit'), 'statusCheckRollup'), 'contexts'),
    'nodes',
  );
  return parseGhPullRequestView(
    jsonEncode({
      ...chosen.cast<String, Object?>(),
      'statusCheckRollup': rollup,
    }),
  );
}

/// One REST run (`/actions/runs`) in [WorkflowRun]'s shape.
WorkflowRun? workflowRunFromRest(Object? json) {
  if (json is! Map) return null;
  return WorkflowRun.fromJson({
    'databaseId': json['id'],
    'workflowName': json['name'],
    'displayTitle': json['display_title'],
    'status': json['status'],
    'conclusion': json['conclusion'],
    'headBranch': json['head_branch'],
    'event': json['event'],
    'url': json['html_url'],
    'createdAt': json['created_at'],
    'attempt': json['run_attempt'],
  });
}

/// The failed steps of one job's log, as `job\tstep\tline` lines — the shape
/// `gh run view --log-failed` prints and [boundRunLog] reads. A line is in a
/// step when its timestamp falls in the step's run; a failed job whose steps
/// carry no times is kept whole.
List<String> failedStepLines(Map<Object?, Object?> job, String log) {
  final jobName = '${job['name'] ?? 'job'}';
  final steps = [
    for (final step in (job['steps'] as List?) ?? const [])
      if (step is Map && step['conclusion'] == 'failure')
        (
          name: '${step['name'] ?? 'step'}',
          from: DateTime.tryParse('${step['started_at']}'),
          to: DateTime.tryParse('${step['completed_at']}'),
        ),
  ];
  final timed = steps.where((s) => s.from != null && s.to != null).toList();
  final lines = const LineSplitter().convert(log);
  if (timed.isEmpty) {
    return [for (final line in lines) '$jobName\t-\t$line'];
  }
  final stamp = RegExp(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z');
  final kept = <String>[];
  for (final line in lines) {
    final match = stamp.firstMatch(line);
    if (match == null) continue;
    final at = DateTime.tryParse('${match.group(1)}Z');
    if (at == null) continue;
    for (final step in timed) {
      // Step times are whole seconds; a line inside the last one still counts.
      if (!at.isBefore(step.from!) &&
          at.isBefore(step.to!.add(const Duration(seconds: 1)))) {
        kept.add('$jobName\t${step.name}\t$line');
        break;
      }
    }
  }
  return kept;
}

/// GitHub operations over its API, as whichever token the credentials give
/// for the repository's host. Git, through [runner] where the checkout lives,
/// says which repository and branch that is.
class GitHubService {
  GitHubService(this.runner, {required this.client, this.environment});

  final CommandRunner runner;
  final GithubClient client;

  /// The environment [runner] reaches, when the caller has the row.
  final ExecutionEnvironment? environment;

  final Map<String, Future<RemoteRepo>> _remotes = {};

  /// The GitHub repository `origin` names for [repo].
  Future<RemoteRepo> remoteOf(EnvironmentPath repo) =>
      _remotes['${repo.environmentId} ${repo.path}'] ??= _readRemote(repo);

  Future<RemoteRepo> _readRemote(EnvironmentPath repo) async {
    final url = await _git(repo, const ['remote', 'get-url', 'origin']);
    final remote = RemoteRepo.parse(url);
    if (remote == null || !remote.slug.contains('/')) {
      throw GitHubException(
        url == null
            ? 'This checkout has no origin remote, so there is no GitHub '
                  'repository to ask.'
            : 'origin ($url) does not name a GitHub repository.',
        refusal: GitHubRefusal.noRemote,
      );
    }
    return remote;
  }

  Future<String?> _git(EnvironmentPath repo, List<String> arguments) async {
    try {
      final result = await runner.run(
        CommandRequest(
          executable: 'git',
          arguments: arguments,
          workingDirectory: repo,
          timeout: const Duration(seconds: 20),
        ),
      );
      final out = result.stdout.trim();
      return result.ok && out.isNotEmpty ? out : null;
    } on CommandException {
      return null;
    }
  }

  /// One call, with access and transport failures in [GitHubException]'s words.
  Future<T> _call<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on GithubNoAccess catch (e) {
      throw GitHubException(
        e.message,
        refusal: GitHubRefusal.noAccess,
        cause: e,
      );
    } on GithubApiException catch (e) {
      throw GitHubException(e.message, status: e.status, cause: e);
    }
  }

  Future<GithubResponse> _get(
    RemoteRepo remote,
    String path, {
    Map<String, String>? query,
    String what = 'GitHub',
    bool allowFailure = false,
  }) => _call(() async {
    final response = await client.rest(remote.host, path, query: query);
    if (!allowFailure) ensureGithubOk(response, what);
    return response;
  });

  String _repoPath(RemoteRepo remote) =>
      'repos/${Uri.encodeComponent(remote.owner)}/'
      '${Uri.encodeComponent(remote.name)}';

  /// Repository metadata for [repo] (name, description, visibility, stars,
  /// default branch).
  Future<GitHubRepo?> getRepository(EnvironmentPath repo) async {
    final remote = await remoteOf(repo);
    final response = await _get(
      remote,
      _repoPath(remote),
      what: 'Reading the repository',
    );
    final body = response.body;
    if (body is! Map) return null;
    final description = '${body['description'] ?? ''}';
    return GitHubRepo(
      nameWithOwner: '${body['full_name'] ?? remote.slug}',
      url: '${body['html_url'] ?? remote.webUrl}',
      isPrivate: body['private'] == true,
      stargazerCount: (body['stargazers_count'] as num?)?.toInt() ?? 0,
      description: description.isEmpty ? null : description,
      defaultBranch: body['default_branch'] as String?,
    );
  }

  /// Open pull requests for [repo].
  Future<List<PullRequest>> listPullRequests(
    EnvironmentPath repo, {
    int limit = 50,
  }) async {
    final remote = await remoteOf(repo);
    final response = await _get(
      remote,
      '${_repoPath(remote)}/pulls',
      query: {'state': 'open', 'per_page': '${limit.clamp(1, 100)}'},
      what: 'Listing pull requests',
    );
    return [
      for (final item in (response.body as List?) ?? const [])
        if (item is Map)
          PullRequest(
            number: (item['number'] as num?)?.toInt() ?? 0,
            title: '${item['title'] ?? ''}',
            state: '${item['state'] ?? ''}'.toUpperCase(),
            author: (item['user'] as Map?)?['login'] as String?,
            url: item['html_url'] as String?,
          ),
    ];
  }

  /// The pull request for [branch] with its checks, or `null` when the
  /// branch definitely has none.
  Future<PullRequestSnapshot?> pullRequestFor(
    EnvironmentPath repo, {
    required String branch,
  }) async {
    final remote = await remoteOf(repo);
    final answer = await _call(
      () => client.graphql(
        remote.host,
        kPullRequestForBranchQuery,
        variables: {
          'owner': remote.owner,
          'name': remote.name,
          'branch': branch,
        },
      ),
    );
    return pullRequestFromGraphql(answer, owner: remote.owner);
  }

  /// Open issues for [repo]; the issues API lists pull requests too, and
  /// those are left out.
  Future<List<Issue>> listIssues(EnvironmentPath repo, {int limit = 50}) async {
    final remote = await remoteOf(repo);
    final response = await _get(
      remote,
      '${_repoPath(remote)}/issues',
      query: {'state': 'open', 'per_page': '${limit.clamp(1, 100)}'},
      what: 'Listing issues',
    );
    return [
      for (final item in (response.body as List?) ?? const [])
        if (item is Map && item['pull_request'] == null)
          Issue(
            number: (item['number'] as num?)?.toInt() ?? 0,
            title: '${item['title'] ?? ''}',
            state: '${item['state'] ?? ''}'.toUpperCase(),
          ),
    ];
  }

  /// The repository's merge settings and open review conversations, in one
  /// GraphQL call. Never throws for a policy reason.
  Future<ForgePolicy> forgePolicyFor(
    EnvironmentPath repo, {
    required int number,
  }) async {
    final remote = await remoteOf(repo);
    final answer = await _call(
      () => client.graphql(
        remote.host,
        kForgePolicyQuery,
        variables: {
          'owner': remote.owner,
          'name': remote.name,
          'number': number,
        },
      ),
    );
    return parseForgePolicy(jsonEncode(answer));
  }

  /// The branch-protection rules on [branch]. A 403 is the non-admin answer,
  /// not a failure.
  Future<BranchProtection> branchProtectionFor(
    EnvironmentPath repo, {
    required String branch,
  }) async {
    final remote = await remoteOf(repo);
    final response = await _get(
      remote,
      '${_repoPath(remote)}/branches/${Uri.encodeComponent(branch)}/protection',
      allowFailure: true,
    );
    if (response.status == 403) return BranchProtection.forbidden;
    if (!response.ok) return BranchProtection.unknown;
    return parseBranchProtection(response.text, branch: branch);
  }

  /// The newest GitHub Actions runs, on [branch] when given.
  Future<List<WorkflowRun>> listWorkflowRuns(
    EnvironmentPath repo, {
    String? branch,
    int limit = 10,
  }) async {
    final remote = await remoteOf(repo);
    final response = await _get(
      remote,
      '${_repoPath(remote)}/actions/runs',
      query: {'branch': ?branch, 'per_page': '${limit.clamp(1, 100)}'},
      what: 'Listing workflow runs',
    );
    final runs = (response.body as Map?)?['workflow_runs'];
    return [
      for (final run in runs is List ? runs : const [])
        ?workflowRunFromRest(run),
    ];
  }

  /// The failed steps' log of run [runId], bounded by [boundRunLog]. Read
  /// only: nothing is re-run.
  Future<WorkflowRunLog> failedRunLog(
    EnvironmentPath repo, {
    required int runId,
  }) async {
    final remote = await remoteOf(repo);
    final jobs = await _get(
      remote,
      '${_repoPath(remote)}/actions/runs/$runId/jobs',
      query: const {'per_page': '100'},
      what: 'Listing the run\'s jobs',
    );
    final list = (jobs.body as Map?)?['jobs'];
    final lines = <String>[];
    for (final job in list is List ? list : const []) {
      if (job is! Map) continue;
      final conclusion = job['conclusion'];
      if (conclusion == null ||
          const {'success', 'skipped', 'neutral'}.contains(conclusion)) {
        continue;
      }
      final log = await _call(
        () => client.rest(
          remote.host,
          '${_repoPath(remote)}/actions/jobs/${job['id']}/logs',
          accept: '*/*',
        ),
      );
      if (!log.ok) continue;
      lines.addAll(failedStepLines(job, log.text));
    }
    return boundRunLog(runId, lines.join('\n'));
  }

  /// Takes a pull request out of draft.
  Future<void> markPullRequestReady(
    EnvironmentPath repo, {
    required int number,
  }) async {
    final remote = await remoteOf(repo);
    final pull = await _get(
      remote,
      '${_repoPath(remote)}/pulls/$number',
      what: 'Reading the pull request',
    );
    final id = (pull.body as Map?)?['node_id'];
    if (id is! String) {
      throw GitHubException('GitHub named no id for pull request #$number.');
    }
    await _call(
      () => client.graphql(
        remote.host,
        _markReadyMutation,
        variables: {'id': id},
      ),
    );
  }

  /// Opens a pull request from the checked-out branch onto the default
  /// branch and returns its URL. The branch must already be pushed.
  Future<String> createPullRequest(
    EnvironmentPath repo, {
    required String title,
    String body = '',
  }) async {
    final remote = await remoteOf(repo);
    final branch = await _git(repo, const [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    if (branch == null || branch == 'HEAD') {
      throw GitHubException(
        'No branch is checked out, so there is nothing to open a pull '
        'request from.',
      );
    }
    final repository = await getRepository(repo);
    final base = repository?.defaultBranch;
    if (base == null) {
      throw GitHubException('GitHub named no default branch to merge into.');
    }
    final response = await _call(() async {
      final response = await client.rest(
        remote.host,
        '${_repoPath(remote)}/pulls',
        method: 'POST',
        body: {'title': title, 'body': body, 'head': branch, 'base': base},
      );
      ensureGithubOk(response, 'Opening the pull request');
      return response;
    });
    final url = (response.body as Map?)?['html_url'];
    if (url is! String) {
      throw GitHubException('GitHub opened the pull request but named no URL.');
    }
    return url;
  }
}
