import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/github.dart';

/// GitHub's REST API through `gh api -i`, as the checkout's own login, in the
/// checkout's own environment. Each path's answer is kept with its ETag and
/// asked again conditionally: a 304 is answered from what was kept.
class GhGithubApi implements GithubApi {
  GhGithubApi(this.runner, this.directory);

  final CommandRunner runner;
  final EnvironmentPath directory;
  final Map<String, ({String etag, Object? body})> _kept = {};

  @override
  Future<GithubAnswer> get(String path) async {
    final kept = _kept[path];
    final CommandResult result;
    try {
      result = await runner.run(
        CommandRequest(
          executable: 'gh',
          arguments: [
            'api',
            '-i',
            '-H',
            'Accept: application/vnd.github+json',
            if (kept != null) ...['-H', 'If-None-Match: ${kept.etag}'],
            path,
          ],
          workingDirectory: directory,
          timeout: const Duration(seconds: 60),
        ),
      );
    } on CommandException catch (error) {
      throw GithubReadException('gh did not run: ${error.message}');
    }
    final answer = parseGhApiAnswer(result.stdout);
    if (answer == null) {
      final said = result.stderr.trim();
      throw GithubReadException(
        said.isEmpty ? 'gh gave no answer' : 'gh said: $said',
      );
    }
    if (answer.status == 304 && kept != null) {
      return GithubAnswer(
        status: 200,
        body: kept.body,
        remaining: answer.remaining,
        resetAt: answer.resetAt,
      );
    }
    if (answer.status == 200 && answer.etag != null) {
      _kept[path] = (etag: answer.etag!, body: answer.body);
    }
    return GithubAnswer(
      status: answer.status,
      body: answer.body,
      remaining: answer.remaining,
      resetAt: answer.resetAt,
    );
  }
}

/// What `gh api -i` printed: the status line, the headers, a blank line and
/// the body. Null when it printed no status line.
({int status, Object? body, String? etag, int? remaining, DateTime? resetAt})?
parseGhApiAnswer(String printed) {
  final text = printed.replaceAll('\r\n', '\n');
  final status = RegExp(r'^HTTP/[\d.]+ (\d{3})').firstMatch(text);
  if (status == null) return null;
  final split = text.indexOf('\n\n');
  final head = split < 0 ? text : text.substring(0, split);
  final rest = split < 0 ? '' : text.substring(split + 2).trim();
  final headers = <String, String>{};
  for (final line in head.split('\n').skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  Object? body;
  if (rest.isNotEmpty) {
    try {
      body = jsonDecode(rest);
    } on FormatException {
      body = rest;
    }
  }
  final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
  return (
    status: int.parse(status.group(1)!),
    body: body,
    etag: headers['etag'],
    remaining: int.tryParse(headers['x-ratelimit-remaining'] ?? ''),
    resetAt: reset == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true),
  );
}
