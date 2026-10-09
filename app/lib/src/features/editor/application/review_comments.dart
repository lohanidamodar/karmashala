import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;
import 'package:karmashala_git/git.dart' show ReviewAuthorKind;
import 'package:riverpod/riverpod.dart';

import '../../../core/util/id_generator_provider.dart';
import '../../git/application/review_threads.dart';
import '../../sessions/application/session_input.dart';

/// A note on lines of a session's change, for the session that made it.
class ReviewComment {
  const ReviewComment({
    required this.id,
    required this.repositoryId,
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.note,
    required this.quote,
    this.threadId,
  });

  final String id;
  final String repositoryId;

  /// Inside the checkout, as git spells it.
  final String path;

  /// 1-based, inclusive.
  final int startLine;
  final int endLine;
  final String note;

  /// The change's lines, as a diff reads them.
  final String quote;

  /// The review thread it was filed as, once it was.
  final String? threadId;

  String get place => startLine == endLine
      ? 'In $path:$startLine'
      : 'In $path:$startLine–$endLine';

  ReviewComment withThread(String? id) => ReviewComment(
    id: this.id,
    repositoryId: repositoryId,
    path: path,
    startLine: startLine,
    endLine: endLine,
    note: note,
    quote: quote,
    threadId: id,
  );
}

/// The one message [comments] are sent as: each placed, its note, the change
/// quoted.
String reviewCommentMessage(List<ReviewComment> comments) {
  String one(ReviewComment c) =>
      '${c.place}: ${c.note.trim()}\n\n```diff\n${c.quote}\n```';
  final body = comments.length == 1
      ? one(comments.single)
      : [
          '${comments.length} comments on your changes:',
          for (var i = 0; i < comments.length; i++)
            '${i + 1}. ${one(comments[i])}',
        ].join('\n\n');
  final threads = [for (final c in comments) ?c.threadId];
  if (threads.isEmpty) return body;
  return '$body\n\n'
      '${threads.length == 1 ? 'It is also review thread' : 'They are also review threads'} '
      '${threads.join(', ')}: answer with review_thread_reply once it is '
      'handled.';
}

/// How sending a batch of comments ended.
sealed class ReviewSendOutcome {
  const ReviewSendOutcome();
}

final class ReviewSent extends ReviewSendOutcome {
  const ReviewSent(this.count);
  final int count;
}

/// Nothing reached the session; the comments are still waiting.
final class ReviewNotSent extends ReviewSendOutcome {
  const ReviewNotSent(this.reason);
  final String reason;
}

/// What sending comments needs: the session's own send — the server's, which
/// queues behind what the person already sent — and filing each comment as a
/// review thread, which may fail without stopping the send.
class ReviewCommentSender {
  const ReviewCommentSender({required this.send, required this.fileThread});

  /// False when nothing runs the session. Throws [SessionPromptRefusal].
  final Future<bool> Function(String sessionId, String text) send;

  /// The new thread's id, or null when it could not be filed.
  final Future<String?> Function(String sessionId, ReviewComment comment)
  fileThread;
}

final reviewCommentSenderProvider = Provider<ReviewCommentSender>(
  (ref) => ReviewCommentSender(
    send: (sessionId, text) =>
        ref.read(sessionInputProvider).send(sessionId, text),
    fileThread: (sessionId, comment) async {
      try {
        final thread = await ref
            .read(reviewThreadServiceProvider)
            .open(
              repositoryId: comment.repositoryId,
              path: comment.path,
              body: comment.note,
              author: 'the user',
              authorKind: ReviewAuthorKind.user,
              startLine: comment.startLine,
              endLine: comment.endLine,
              excerpt: comment.quote,
              sessionId: sessionId,
            );
        return thread.id;
      } on Object {
        // A comment that cannot be anchored is still worth sending.
        return null;
      }
    },
  ),
);

/// Comments written and not yet sent, by session: sent together, as one
/// message, with "Send N comments".
class ReviewCommentDrafts extends Notifier<Map<String, List<ReviewComment>>> {
  @override
  Map<String, List<ReviewComment>> build() => const {};

  List<ReviewComment> of(String sessionId) => state[sessionId] ?? const [];

  ReviewComment add(
    String sessionId, {
    required String repositoryId,
    required String path,
    required int startLine,
    required int endLine,
    required String note,
    required String quote,
  }) {
    final comment = ReviewComment(
      id: ref.read(idGeneratorProvider).newId(),
      repositoryId: repositoryId,
      path: path,
      startLine: startLine,
      endLine: endLine,
      note: note.trim(),
      quote: quote,
    );
    state = {
      ...state,
      sessionId: [...of(sessionId), comment],
    };
    return comment;
  }

  void remove(String sessionId, String id) => state = {
    ...state,
    sessionId: [
      for (final c in of(sessionId))
        if (c.id != id) c,
    ],
  };

  void clear(String sessionId) => state = {...state}..remove(sessionId);

  /// Sends every waiting comment of [sessionId] as one message. Each is filed
  /// as a review thread first, once; on a refusal they all stay waiting.
  Future<ReviewSendOutcome> send(String sessionId) async {
    final waiting = of(sessionId);
    if (waiting.isEmpty) return const ReviewSent(0);
    final sender = ref.read(reviewCommentSenderProvider);
    final filed = <ReviewComment>[
      for (final c in waiting)
        c.threadId != null
            ? c
            : c.withThread(await sender.fileThread(sessionId, c)),
    ];
    final byId = {for (final c in filed) c.id: c};
    if (ref.mounted) {
      state = {
        ...state,
        sessionId: [for (final c in of(sessionId)) byId[c.id] ?? c],
      };
    }
    final bool sent;
    try {
      sent = await sender.send(sessionId, reviewCommentMessage(filed));
    } on SessionPromptRefusal catch (refusal) {
      return ReviewNotSent(refusal.message);
    }
    if (!sent) {
      return const ReviewNotSent(
        'Nothing is running that session here, so the comments are kept.',
      );
    }
    if (ref.mounted) {
      state = {
        ...state,
        sessionId: [
          for (final c in of(sessionId))
            if (!byId.containsKey(c.id)) c,
        ],
      };
    }
    return ReviewSent(filed.length);
  }
}

final reviewCommentDraftsProvider =
    NotifierProvider<ReviewCommentDrafts, Map<String, List<ReviewComment>>>(
      ReviewCommentDrafts.new,
    );
