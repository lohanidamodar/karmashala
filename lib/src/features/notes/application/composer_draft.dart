import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Text queued for a session's message composer, keyed by session id.
///
/// This is how a note reaches an agent, and the reason it is a queue rather
/// than a call: **a note is not sent, it is offered**. Sending a note back puts
/// its words in the box under the transcript, where the user reads them,
/// changes their mind about half of them, and presses Enter — or does not. A
/// note is a deferred instruction the user wrote for themselves weeks ago;
/// dispatching one silently would be Karmashala deciding it was still right.
///
/// The draft survives until the composer picks it up, so sending back to a
/// session that is not on screen leaves the text waiting there rather than
/// dropping it. Nothing here touches the agent: from the composer onwards it is
/// the ordinary `sessionActionsProvider.continueSession` path, the same one
/// typing into the box uses.
class ComposerDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Offers [text] to [sessionId]'s composer. A second offer before the first
  /// is taken appends rather than replaces: two notes sent back in a row are
  /// two ideas, and losing one silently is the worse failure.
  void queue(String sessionId, String text) {
    final pending = state[sessionId];
    state = {
      ...state,
      sessionId: pending == null || pending.isEmpty
          ? text
          : '$pending\n\n$text',
    };
  }

  /// Takes whatever is waiting for [sessionId], leaving nothing behind.
  String? take(String sessionId) {
    final pending = state[sessionId];
    if (pending == null) return null;
    state = {...state}..remove(sessionId);
    return pending;
  }
}

final composerDraftProvider =
    NotifierProvider<ComposerDrafts, Map<String, String>>(ComposerDrafts.new);
