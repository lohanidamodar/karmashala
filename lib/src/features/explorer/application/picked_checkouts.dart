import 'package:riverpod/riverpod.dart';

/// Which checkout the user picked while working in a given session. The context
/// otherwise recomputes on every tab switch, so a pick was forgotten the moment
/// you looked elsewhere. In memory only: a pick is not a stored property.
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

/// The session the side panel's context is currently following, so a pick is
/// filed against the session it was made in. Plain state rather than the pane
/// lookup it mirrors: that would build the whole terminal controller.
class FollowedSession extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? sessionId) => state = sessionId;
}

final followedSessionProvider = NotifierProvider<FollowedSession, String?>(
  FollowedSession.new,
);
