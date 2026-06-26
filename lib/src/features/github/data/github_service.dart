import 'dart:convert';

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/issue.dart';
import '../domain/pull_request.dart';

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
        ),
  ];
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

  /// Open pull requests for [repo].
  Future<List<PullRequest>> listPullRequests(
    EnvironmentPath repo, {
    int limit = 50,
  }) async {
    final result = await _gh(repo, [
      'pr',
      'list',
      '--json',
      'number,title,state,author',
      '--limit',
      '$limit',
    ]);
    if (!result.ok) {
      throw GitHubException('gh pr list failed: ${result.stderr.trim()}');
    }
    return parseGhPullRequests(result.stdout);
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
