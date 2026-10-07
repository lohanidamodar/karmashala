import '../domain/automation.dart';
import '../domain/github_trigger.dart';
import '../store/automation_dao.dart';

/// One answer from GitHub's REST API. [body] is decoded JSON; a 304 has
/// already been answered from the reader's cache, so it is never seen here.
class GithubAnswer {
  const GithubAnswer({
    required this.status,
    required this.body,
    this.remaining,
    this.resetAt,
  });

  final int status;
  final Object? body;

  /// `X-RateLimit-Remaining` and `-Reset`, when GitHub sent them.
  final int? remaining;
  final DateTime? resetAt;
}

/// Reads one REST path (`repos/o/r/pulls?…`) as the checkout's `gh` login.
/// Throws [GithubReadException] when it cannot.
abstract interface class GithubApi {
  Future<GithubAnswer> get(String path);
}

class GithubReadException implements Exception {
  const GithubReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Below this many calls left in the hour, the poller waits for the reset —
/// the rest of the budget is the person's own `gh` and the app's.
const int kGithubRateFloor = 200;

/// How many open pull requests a review or check look reads, newest first.
const int kGithubPullsWatched = 10;

/// How long an answered item's key is kept; well past what GitHub lists.
const Duration kGithubSeenKept = Duration(days: 30);

/// Polls GitHub for every enabled GitHub automation at its own interval,
/// answers each item once, and never answers what was there before its
/// first look. One budget for all of them, kept under GitHub's rate limit.
class GithubPoller {
  GithubPoller({
    required this.dao,
    required this.apiFor,
    required this.fire,
    required this.now,
    this.log,
  });

  final AutomationDao dao;

  /// `gh` where [Automation]'s checkout is, or null when there is none.
  final GithubApi? Function(Automation automation) apiFor;

  /// Acts on one event that passed its automation's filters.
  final Future<void> Function(Automation automation, GithubEvent event) fire;
  final DateTime Function() now;
  final void Function(String message)? log;

  /// Until when GitHub's budget is spent, or null.
  DateTime? waitingUntil;
  Future<void>? _sweeping;

  /// Calls made, for tests and the log.
  int calls = 0;

  /// One look at every automation that is due. A sweep already running is
  /// joined rather than doubled.
  Future<void> sweep() =>
      _sweeping ??= _sweep().whenComplete(() => _sweeping = null);

  Future<void> _sweep() async {
    final at = now();
    if (waitingUntil case final until? when at.isBefore(until)) return;
    waitingUntil = null;
    for (final rule in dao.githubRules()) {
      final trigger = rule.github!;
      if (!rule.enabled) {
        dao.forgetGithubLook(rule.id);
        continue;
      }
      final polled = dao.githubPolledAt(rule.id);
      if (polled != null && at.difference(polled) < trigger.pollEvery) {
        continue;
      }
      final api = apiFor(rule);
      if (api == null) continue;
      final priming = dao.githubPrimedAt(rule.id) == null;
      final List<GithubEvent> events;
      try {
        events = await _read(trigger, api);
      } on GithubReadException catch (error) {
        log?.call('github: "${rule.name}" could not look: $error');
        dao.markGithubPolled(rule.id, at);
        if (waitingUntil != null) return;
        continue;
      }
      dao.markGithubPolled(rule.id, at);
      for (final event in events) {
        if (!dao.markGithubSeen(rule.id, event.dedupeKey(rule.id), at)) {
          continue;
        }
        if (priming) continue;
        // A comment's pull request is read only once it is new to us.
        final needsPull = event.kind.isPullRequest && event.branch.isEmpty;
        final firstCut = needsPull
            ? trigger.copyWith(branch: '', label: '')
            : trigger;
        if (githubEventRefusal(firstCut, event) != null) continue;
        var full = event;
        if (needsPull) {
          try {
            full = withPull(event, await _get(api, _pull(trigger, event)));
          } on GithubReadException catch (error) {
            log?.call('github: #${event.number} could not be read: $error');
            continue;
          }
          if (githubEventRefusal(trigger, full) != null) continue;
        }
        await fire(rule, full);
      }
      if (waitingUntil != null) return;
    }
    dao.pruneGithubSeen(at.subtract(kGithubSeenKept));
  }

  String _repo(AutomationGithubTrigger trigger) =>
      'repos/${trigger.repository}';

  String _pull(AutomationGithubTrigger trigger, GithubEvent event) =>
      '${_repo(trigger)}/pulls/${event.number}';

  Future<Object?> _get(GithubApi api, String path) async {
    calls++;
    final answer = await api.get(path);
    final remaining = answer.remaining;
    if ((remaining != null && remaining < kGithubRateFloor) ||
        answer.status == 429 ||
        (answer.status == 403 && remaining == 0)) {
      waitingUntil = answer.resetAt ?? now().add(const Duration(minutes: 15));
      log?.call(
        'github: $remaining calls left this hour; waiting until '
        '$waitingUntil before looking again.',
      );
    }
    if (answer.status >= 400) {
      throw GithubReadException('GitHub answered ${answer.status} for $path');
    }
    return answer.body;
  }

  Future<List<GithubEvent>> _read(
    AutomationGithubTrigger trigger,
    GithubApi api,
  ) async {
    final repo = _repo(trigger);
    switch (trigger.kind) {
      case GithubTriggerKind.prComment:
        return commentEvents(
          await _get(
            api,
            '$repo/issues/comments?sort=created&direction=desc&per_page=50',
          ),
        );
      case GithubTriggerKind.prMerged:
        return mergedEvents(
          await _get(
            api,
            '$repo/pulls?state=closed&sort=updated&direction=desc&per_page=30',
          ),
        );
      case GithubTriggerKind.issueLabeled || GithubTriggerKind.issueAssigned:
        return issueEvents(
          trigger.kind,
          await _get(api, '$repo/issues/events?per_page=50'),
        );
      case GithubTriggerKind.prReview || GithubTriggerKind.checkFailed:
        final pulls = _list(
          await _get(
            api,
            '$repo/pulls?state=open&sort=updated&direction=desc'
            '&per_page=$kGithubPullsWatched',
          ),
        );
        final events = <GithubEvent>[];
        for (final pull in pulls) {
          if (!githubBranchMatches(trigger.branch, _headRef(pull))) continue;
          final number = pull['number'];
          if (trigger.kind == GithubTriggerKind.prReview) {
            events.addAll(
              reviewEvents(
                pull,
                await _get(api, '$repo/pulls/$number/reviews?per_page=50'),
              ),
            );
          } else {
            final sha = (pull['head'] as Map?)?['sha'];
            if (sha is! String) continue;
            events.addAll(
              checkEvents(
                pull,
                await _get(api, '$repo/commits/$sha/check-runs?per_page=50'),
              ),
            );
          }
          if (waitingUntil != null) break;
        }
        return events;
    }
  }
}

List<Map<String, Object?>> _list(Object? body) => [
  if (body is List)
    for (final item in body)
      if (item is Map<String, Object?>) item,
];

String _string(Object? value) => value is String ? value : '';

String _login(Object? user) => user is Map ? _string(user['login']) : '';

String _headRef(Map<String, Object?> pull) =>
    _string((pull['head'] as Map?)?['ref']);

List<String> _labels(Object? labels) => [
  if (labels is List)
    for (final label in labels)
      if (label is Map && label['name'] is String) label['name'] as String,
];

int _numberFromUrl(String url) =>
    int.tryParse(
      url.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => ''),
    ) ??
    0;

/// [event] with its pull request's title, page, branch and labels.
GithubEvent withPull(GithubEvent event, Object? pull) {
  if (pull is! Map<String, Object?>) return event;
  return GithubEvent(
    kind: event.kind,
    itemId: event.itemId,
    number: event.number,
    url: _string(pull['html_url']),
    title: _string(pull['title']),
    body: event.body,
    branch: _headRef(pull),
    author: event.author,
    association: event.association,
    labels: _labels(pull['labels']),
    checkName: event.checkName,
    checkSummary: event.checkSummary,
  );
}

/// Comments on pull requests, oldest first. An issue's comments are left
/// out; the pull request's own details come later, for new ones only.
List<GithubEvent> commentEvents(Object? body) => [
  for (final comment in _list(body).reversed)
    if (_string(comment['html_url']).contains('/pull/'))
      GithubEvent(
        kind: GithubTriggerKind.prComment,
        itemId: '${comment['id']}',
        number: _numberFromUrl(_string(comment['issue_url'])),
        url: '',
        body: _string(comment['body']),
        author: _login(comment['user']),
        association: _string(comment['author_association']),
      ),
];

/// A pull request's submitted reviews, oldest first.
List<GithubEvent> reviewEvents(Map<String, Object?> pull, Object? body) => [
  for (final review in _list(body))
    if (review['state'] != 'PENDING')
      withPull(
        GithubEvent(
          kind: GithubTriggerKind.prReview,
          itemId: '${review['id']}',
          number: pull['number'] as int? ?? 0,
          url: '',
          body: _string(review['body']),
          author: _login(review['user']),
          association: _string(review['author_association']),
        ),
        pull,
      ),
];

/// The failed check runs on a pull request's head.
List<GithubEvent> checkEvents(Map<String, Object?> pull, Object? body) {
  final runs = body is Map ? body['check_runs'] : null;
  return [
    for (final run in _list(runs))
      if (run['conclusion'] == 'failure' || run['conclusion'] == 'timed_out')
        withPull(
          GithubEvent(
            kind: GithubTriggerKind.checkFailed,
            itemId: '${run['id']}',
            number: pull['number'] as int? ?? 0,
            url: '',
            author: _login(pull['user']),
            association: _string(pull['author_association']),
            checkName: _string(run['name']),
            checkSummary: [
              _string((run['output'] as Map?)?['title']),
              _string((run['output'] as Map?)?['summary']),
            ].where((s) => s.isNotEmpty).join('\n'),
          ),
          pull,
        ),
  ];
}

/// Merged pull requests, oldest first.
List<GithubEvent> mergedEvents(Object? body) => [
  for (final pull in _list(body).reversed)
    if (pull['merged_at'] != null)
      withPull(
        GithubEvent(
          kind: GithubTriggerKind.prMerged,
          itemId: 'merged',
          number: pull['number'] as int? ?? 0,
          url: '',
          author: _login(pull['user']),
          association: _string(pull['author_association']),
        ),
        pull,
      ),
];

/// Issues labelled or assigned, oldest first; pull requests are left out.
List<GithubEvent> issueEvents(GithubTriggerKind kind, Object? body) {
  final word = kind == GithubTriggerKind.issueLabeled ? 'labeled' : 'assigned';
  return [
    for (final event in _list(body).reversed)
      if (event['event'] == word &&
          event['issue'] is Map &&
          (event['issue'] as Map)['pull_request'] == null)
        GithubEvent(
          kind: kind,
          itemId: '${event['id']}',
          number: (event['issue'] as Map)['number'] as int? ?? 0,
          url: _string((event['issue'] as Map)['html_url']),
          title: _string((event['issue'] as Map)['title']),
          body: _string((event['issue'] as Map)['body']),
          author: _login(event['actor']),
          labels: _labels((event['issue'] as Map)['labels']),
          label: _string((event['label'] as Map?)?['name']),
          assignee: _login(event['assignee']),
        ),
  ];
}
