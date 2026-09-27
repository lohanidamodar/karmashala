import 'package:agent_cli/descriptors.dart';
import 'attention_json.dart';
import 'notification_policy.dart';
import 'watched_session.dart';

/// Why a session is holding the user up.
enum AttentionKind {
  /// Waiting for the user to approve something.
  needsInput,

  /// Ended in error.
  failed;

  /// What [status] is asking of the user right now, or `null`. Derived from
  /// [AgentNotificationPolicy.reasonForStatus] so the two cannot disagree.
  static AttentionKind? forStatus(AgentActivityStatus status) =>
      switch (AgentNotificationPolicy.reasonForStatus(status)) {
        NotificationReason.needsInput => AttentionKind.needsInput,
        NotificationReason.failed => AttentionKind.failed,
        _ => null,
      };
}

/// One session currently waiting on the user, as listed in the tray menu.
/// State, not an event: it survives a missed toast and ignores window focus.
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

  Map<String, Object?> toJson() => {
    'session': session.toJson(),
    'kind': kind.name,
  };

  static SessionAttention fromJson(Object? json) {
    final map = attentionObject(json, 'session attention');
    return SessionAttention(
      session: WatchedSession.fromJson(map['session']),
      kind: attentionEnum(AttentionKind.values, map, 'kind'),
    );
  }
}
