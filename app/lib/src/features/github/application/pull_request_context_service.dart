/// Gathering a pull request's context, sending it, and keeping what was sent.
///
/// The last of those is the point. A block of context pasted into an agent
/// collapses in its own transcript — Claude Code renders anything over 800
/// characters as `[Pasted text #N]` — so a week later nobody can say what the
/// agent was actually told. Every card sent from here is recorded verbatim
/// against the session, and can be read back exactly as it left.
library;

import '../../workspaces/data/workspace_data.dart';
import 'dart:convert';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_session/events.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../git/application/review_threads.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_git/pull_request_context.dart';

/// The event type a sent card is filed under.
const String kPullRequestContextEvent = 'context.pull_request';

/// A card that was sent, read back out of the session's own record.
class SentContextCard {
  const SentContextCard({
    required this.at,
    required this.prompt,
    required this.parts,
    this.pullRequestNumber,
  });

  final DateTime at;

  /// **Exactly** the text the agent was given. Not a summary of it.
  final String prompt;

  /// The parts the user ticked, by name, so a reader can see what was offered
  /// and left out as well as what went.
  final List<String> parts;
  final int? pullRequestNumber;
}

/// Reads a pull request's context, sends it, and files what it sent.
class PullRequestContextService {
  PullRequestContextService(this._ref);

  final Ref _ref;
  static final _log = AppLogger.named('github.context');

  /// Everything a card for [sessionId] could draw on, or null when this
  /// session has no pull request Karmashala has read.
  Future<PullRequestContextSource?> sourceFor(String sessionId) async {
    final delivery = await _ref.read(sessionDeliveryProvider(sessionId).future);
    final snapshot = delivery.pullRequest;
    if (snapshot == null) return null;
    return PullRequestContextSource(
      snapshot: snapshot,
      failingChecks: _failingChecks(snapshot),
      reviews: await _reviews(sessionId),
    );
  }

  /// Check names GitHub reported as failing.
  ///
  /// `ChecksSummary` counts rather than names, so this reports the count as
  /// one line rather than inventing names it was never given: a card must not
  /// hand an agent a check name that does not exist.
  List<String> _failingChecks(PullRequestSnapshot snapshot) {
    final failed = snapshot.checks.failed;
    if (failed == 0) return const [];
    return [
      '$failed check${failed == 1 ? '' : 's'} reported as failing. '
          'Karmashala reads the counts, not the names — `gh pr checks` lists '
          'them.',
    ];
  }

  /// This session's open review conversations, as lines.
  Future<List<ReviewCommentLine>> _reviews(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return const [];
    final repositoryId = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId)
        ?.id;
    if (repositoryId == null) return const [];
    try {
      final index = await _ref.read(reviewThreadsOf(repositoryId).future);
      return [
        for (final entry in index.all)
          if (entry.thread.status == ReviewThreadStatus.open &&
              entry.thread.body.trim().isNotEmpty)
            ReviewCommentLine(
              where: entry.anchor.location,
              body: entry.thread.body,
              author: entry.thread.comments.firstOrNull?.author,
            ),
      ];
    } on Object catch (error) {
      _log.warning('Could not read review threads: $error');
      return const [];
    }
  }

  /// Sends [prompt] to [sessionId] and files it. The prompt is passed in
  /// rather than rebuilt here so that what was previewed is what is sent.
  Future<void> send({
    required String sessionId,
    required String prompt,
    required Set<PullRequestContextPart> parts,
    int? pullRequestNumber,
  }) async {
    // Filed **before** the send: a card that failed to reach the agent is
    // still something the user tried, and a record written only on success
    // would leave the one case worth investigating with no trace.
    _record(
      sessionId: sessionId,
      prompt: prompt,
      parts: parts,
      pullRequestNumber: pullRequestNumber,
    );
    await _ref.read(sessionActionsProvider).continueSession(sessionId, prompt);
  }

  void _record({
    required String sessionId,
    required String prompt,
    required Set<PullRequestContextPart> parts,
    int? pullRequestNumber,
  }) {
    try {
      _ref
          .read(sessionEventDaoProvider)
          .append(
            SessionEvent(
              sessionId: sessionId,
              seq: 0,
              type: kPullRequestContextEvent,
              payload: jsonEncode({
                'prompt': prompt,
                'parts': [
                  for (final part in PullRequestContextPart.values)
                    if (parts.contains(part)) part.name,
                ],
                'pullRequest': pullRequestNumber,
              }),
              createdAt: _ref.read(clockProvider).nowUtc(),
            ),
          );
    } on Object catch (error, stack) {
      // Losing the record must not lose the send.
      _log.warning('Could not record the context card.', error, stack);
    }
  }

  /// Every card sent in [sessionId], newest first.
  List<SentContextCard> sentIn(String sessionId) {
    final cards = <SentContextCard>[];
    try {
      for (final event
          in _ref.read(sessionEventDaoProvider).listForSession(sessionId)) {
        if (event.type != kPullRequestContextEvent) continue;
        final decoded = jsonDecode(event.payload);
        if (decoded is! Map<String, Object?>) continue;
        cards.add(
          SentContextCard(
            at: event.createdAt,
            prompt: (decoded['prompt'] as String?) ?? '',
            parts: [
              for (final part in (decoded['parts'] as List?) ?? const [])
                if (part is String) part,
            ],
            pullRequestNumber: (decoded['pullRequest'] as num?)?.round(),
          ),
        );
      }
    } on Object catch (error) {
      _log.warning('Could not read the sent context cards: $error');
    }
    return cards.reversed.toList();
  }
}

final pullRequestContextServiceProvider = Provider<PullRequestContextService>(
  PullRequestContextService.new,
);

/// One session's sent cards, for the panel that shows them.
final sentContextCardsProvider = Provider.autoDispose
    .family<List<SentContextCard>, String>(
      (ref, sessionId) =>
          ref.read(pullRequestContextServiceProvider).sentIn(sessionId),
    );
