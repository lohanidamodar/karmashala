import 'dart:convert';

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/github_repo.dart';
import '../domain/issue.dart';
import '../domain/pull_request.dart';
import '../domain/pull_request_snapshot.dart';

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
    reviewDecision: ReviewDecision.parse(
      _stringOrNull(decoded['reviewDecision']),
    ),
    checks: parseCheckRollup(decoded['statusCheckRollup']),
    headRefName: _stringOrNull(decoded['headRefName']),
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
      'number,title,state,url,isDraft,mergeable,reviewDecision,'
          'statusCheckRollup,headRefName',
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
