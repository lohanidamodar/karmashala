import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sessions/application/session_providers.dart';
import '../../snippets/application/snippet_insertion.dart';
import '../../snippets/domain/command_snippet.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

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

/// Where a note or a todo went when it was offered to a session.
enum SessionOfferOutcome {
  /// Typed at the session's prompt and left there, because its terminal is the
  /// face on screen.
  typedIntoTerminal,

  /// Queued for the composer, because its conversation is the face on screen.
  queuedForComposer,

  /// Queued, and nothing is showing it: the session runs in no live pane.
  waitingForAPane,
}

/// Offers [text] to [sessionId] **in the face that session is already
/// showing**.
///
/// Terminal up, the text is typed at the prompt through [insertSnippet] — the
/// one path into a pane, which never presses Enter there. Chat up, it is
/// queued for the composer. Either way it is *offered*: nothing here submits.
///
/// The face is **read, never written**. Revealing the conversation (`e7adebe6`)
/// stopped a note vanishing into an unmounted composer, but forced the chat
/// open over whatever the user was working in; reading the face answers the
/// same question without moving anybody.
SessionOfferOutcome offerToSession(
  WidgetRef ref, {
  required String sessionId,
  required String text,
}) {
  final paneId = ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
  // Answered before the terminals are read at all: a session in no pane has no
  // face to follow, and mounting the controller to find that out would start
  // the pane machinery for a panel that never needed it.
  if (paneId == null) {
    ref.read(composerDraftProvider.notifier).queue(sessionId, text);
    return SessionOfferOutcome.waitingForAPane;
  }
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  final state = ref.read(terminalSessionsControllerProvider);
  // No group means no face to follow — a pane the layout has lost. Treated as
  // the composer, which is the destination that keeps the text.
  final groupId = terminals.groupOfPane(paneId);
  if (groupId != null &&
      ref.read(terminalVisibleInGroupProvider(groupId)) &&
      insertSnippet(
        terminals: terminals,
        state: state,
        snippet: _offered(text),
        paneId: paneId,
      ).delivered) {
    return SessionOfferOutcome.typedIntoTerminal;
  }
  ref.read(composerDraftProvider.notifier).queue(sessionId, text);
  // A pane whose process has exited cannot be typed into and shows no
  // composer either, so it is waiting rather than delivered.
  return state.livenessOf(paneId).isLive
      ? SessionOfferOutcome.queuedForComposer
      : SessionOfferOutcome.waitingForAPane;
}

/// What the user is offered, said the one way that will not be misread.
String sessionOfferMessage(SessionOfferOutcome outcome, String title) =>
    switch (outcome) {
      SessionOfferOutcome.typedIntoTerminal =>
        'Typed into $title’s terminal, unsent.',
      SessionOfferOutcome.queuedForComposer =>
        'Sent to $title’s message box.',
      SessionOfferOutcome.waitingForAPane =>
        'Waiting for $title — no terminal is running it.',
    };

/// [text] as [insertSnippet] takes it: a one-line command, never submitted.
///
/// A throwaway rather than a second write path — `singleLine` and the rule
/// that a pane is typed into and not sent to both live in there.
CommandSnippet _offered(String text) => CommandSnippet(
  id: 'offered',
  label: 'Offered text',
  command: text,
  createdAt: DateTime.utc(1970),
  updatedAt: DateTime.utc(1970),
);
