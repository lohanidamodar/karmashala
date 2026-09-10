import 'package:agent_cli/descriptors.dart';
import 'evidence_line.dart';
import 'notification_policy.dart';
import 'watched_session.dart';

/// One notification-worthy event, waiting to be delivered.
class PendingNotification {
  const PendingNotification({
    required this.session,
    required this.reason,
    this.evidence = const [],
    this.waiting = AgentWaitKind.unrecorded,
  });

  final WatchedSession session;
  final NotificationReason reason;

  /// What the agent is waiting *on*: the reason says the user is held up, this
  /// says whether anything is actually there to confirm.
  final AgentWaitKind waiting;

  /// The agent's own words, when the source that reported this carried any.
  /// Empty is the normal case — see [AgentStatusReport.evidence].
  final List<String> evidence;

  @override
  String toString() => 'PendingNotification($session, ${reason.name})';
}

/// What to hand the OS: a single toast.
class NotificationRequest {
  const NotificationRequest({
    required this.title,
    required this.body,
    this.payload,
  });

  final String title;
  final String body;

  /// Opaque data carried back when the toast is clicked; see
  /// [NotificationPayload].
  final String? payload;

  @override
  String toString() => 'NotificationRequest($title, $body)';
}

/// Encodes which session a toast should open, as a string the OS can round-trip
/// (Windows hands the payload back verbatim on activation).
class NotificationPayload {
  const NotificationPayload({required this.openId, required this.imported});

  final String openId;
  final bool imported;

  String encode() => '${imported ? 'imported' : 'native'}:$openId';

  static NotificationPayload? decode(String? raw) {
    if (raw == null) return null;
    final split = raw.indexOf(':');
    if (split <= 0 || split == raw.length - 1) return null;
    final kind = raw.substring(0, split);
    if (kind != 'imported' && kind != 'native') return null;
    return NotificationPayload(
      openId: raw.substring(split + 1),
      imported: kind == 'imported',
    );
  }
}

/// Turns everything inside one coalescing window into at most one interruption:
/// three agents finishing become one toast that names them, not three.
class NotificationCoalescer {
  const NotificationCoalescer({this.maxNamed = 3, this.maxQuoted = 120});

  /// How many sessions a summary names before it falls back to "+N more".
  final int maxNamed;

  /// How much of the agent's own words a single-session toast carries.
  final int maxQuoted;

  NotificationRequest? summarize(List<PendingNotification> events) {
    if (events.isEmpty) return null;

    // One line per session: a session that finished and then asked for approval
    // in the same window is one thing, described by its latest state.
    final latest = <String, PendingNotification>{};
    for (final event in events) {
      latest['${event.session.key}'] = event;
    }
    final unique = latest.values.toList();

    if (unique.length == 1) {
      final only = unique.single;
      return NotificationRequest(
        title: _headline(only.reason, only.waiting),
        body: _body(only),
        payload: NotificationPayload(
          openId: only.session.openId,
          imported: only.session.imported,
        ).encode(),
      );
    }

    final needsUser = unique.where((e) => e.reason.needsUser).length;
    final title = switch (needsUser) {
      0 => '${unique.length} agents finished',
      final int n when n == unique.length => '$n sessions need you',
      _ => '${unique.length} agent updates',
    };

    final named = unique.take(maxNamed).map((e) => e.session.label).toList();
    final remaining = unique.length - named.length;
    final body = remaining > 0
        ? '${named.join(' · ')} · +$remaining more'
        : named.join(' · ');

    // A summary covers several sessions, so clicking it opens the app rather
    // than guessing which one was meant.
    return NotificationRequest(title: title, body: body);
  }

  /// The session, and what the agent said about it. No evidence means the label
  /// alone: a toast that invented a description is worse than a bare one.
  String _body(PendingNotification event) {
    final quoted = evidenceLine(event.evidence, max: maxQuoted);
    return quoted == null
        ? event.session.label
        : '${event.session.label} — $quoted';
  }

  /// `needsInput` is two sentences: Claude's `Notification` hook fires for a
  /// permission prompt and for its 60s idle nudge; unrecorded takes the weaker.
  String _headline(NotificationReason reason, AgentWaitKind waiting) =>
      switch (reason) {
    NotificationReason.finished => 'Agent finished',
    NotificationReason.needsInput =>
      waiting == AgentWaitKind.approval
          ? 'Agent needs your approval'
          : 'Agent is waiting for you',
    NotificationReason.failed => 'Agent failed',
    NotificationReason.checksFailed => 'Checks failed',
    NotificationReason.changesRequested => 'Changes requested',
    NotificationReason.readyToMerge => 'Ready to merge',
  };
}
