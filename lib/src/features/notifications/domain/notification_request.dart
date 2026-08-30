import 'notification_policy.dart';
import 'watched_session.dart';

/// One notification-worthy event, waiting to be delivered.
class PendingNotification {
  const PendingNotification({required this.session, required this.reason});

  final WatchedSession session;
  final NotificationReason reason;

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

/// Turns everything that happened inside one coalescing window into at most one
/// interruption.
///
/// Three agents finishing within five seconds is one event as far as the user
/// is concerned, so it becomes one toast that names them, not three that fight
/// for the same corner of the screen.
class NotificationCoalescer {
  const NotificationCoalescer({this.maxNamed = 3});

  /// How many sessions a summary names before it falls back to "+N more".
  final int maxNamed;

  NotificationRequest? summarize(List<PendingNotification> events) {
    if (events.isEmpty) return null;

    // One line per session: a session that finished and then asked for approval
    // inside the same window is one thing that happened, described by its
    // latest state.
    final latest = <String, PendingNotification>{};
    for (final event in events) {
      latest['${event.session.key}'] = event;
    }
    final unique = latest.values.toList();

    if (unique.length == 1) {
      final only = unique.single;
      return NotificationRequest(
        title: _headline(only.reason),
        body: only.session.label,
        payload: NotificationPayload(
          openId: only.session.openId,
          imported: only.session.imported,
        ).encode(),
      );
    }

    final needsUser = unique
        .where((e) => e.reason != NotificationReason.finished)
        .length;
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

  String _headline(NotificationReason reason) => switch (reason) {
    NotificationReason.finished => 'Agent finished',
    NotificationReason.needsInput => 'Agent needs your approval',
    NotificationReason.failed => 'Agent failed',
  };
}
