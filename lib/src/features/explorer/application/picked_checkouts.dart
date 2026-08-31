import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which checkout the user picked while working in a given session.
///
/// **Why a pick has to be remembered.** The context follows the active session:
/// activating another terminal tab recomputes the panel's checkout from the
/// session's working directory. That is right for a session you have said
/// nothing about, and wrong for one you have — pick the clone a session's
/// subagents work in, switch tabs, come back, and the panel was on the hub
/// again. The owner reported the scoped surfaces describing the wrong checkout
/// three times, and this is the half of it that survives a rescan: a pick that
/// is forgotten the moment you look at another tab is not a choice, it is a
/// hint.
///
/// Kept in memory, so it lasts the app run. A pick is a statement about the
/// work in front of you rather than a property of the session worth storing.
class PickedCheckouts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  /// Remembers that [sessionId]'s work is in [repositoryId].
  void remember(String sessionId, String repositoryId) =>
      state = {...state, sessionId: repositoryId};

  /// What was picked for [sessionId], if anything.
  String? forSession(String? sessionId) =>
      sessionId == null ? null : state[sessionId];
}

final pickedCheckoutsProvider =
    NotifierProvider<PickedCheckouts, Map<String, String>>(PickedCheckouts.new);

/// The session the side panel's context is currently following.
///
/// Written by `SessionContext.follow`, and read when a pick is made so the pick
/// is filed against the session it was made in. Deliberately plain state rather
/// than the pane lookup it mirrors: asking which session owns the active pane
/// builds the whole terminal controller, and picking a checkout has no business
/// starting a terminal.
class FollowedSession extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? sessionId) => state = sessionId;
}

final followedSessionProvider = NotifierProvider<FollowedSession, String?>(
  FollowedSession.new,
);
