import 'watched_session.dart';

/// Why a session is holding the user up.
enum AttentionKind {
  /// Waiting for the user to approve something.
  needsInput,

  /// Ended in error.
  failed,
}

/// One session currently waiting on the user, as listed in the tray menu.
///
/// This is *state*, not an event: it is derived from what sessions are doing
/// right now, so it survives a missed notification and is not gated on window
/// focus. A tray icon is ambient; a toast is an interruption.
class SessionAttention {
  const SessionAttention({required this.session, required this.kind});

  final WatchedSession session;
  final AttentionKind kind;

  String get menuLabel => switch (kind) {
    AttentionKind.needsInput => '${session.label} — needs approval',
    AttentionKind.failed => '${session.label} — failed',
  };

  @override
  bool operator ==(Object other) =>
      other is SessionAttention &&
      other.session == session &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(session, kind);

  @override
  String toString() => 'SessionAttention($session, ${kind.name})';
}
