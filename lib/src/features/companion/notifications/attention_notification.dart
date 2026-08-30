/// The pure mapping from an attention event to the local notification shown
/// for it. Kept plugin-free so it is unit-testable; the plugin wrapper in
/// `companion_notifier.dart` is the only file that touches
/// `flutter_local_notifications`.
library;

import '../client/companion_gateway.dart';

/// One notification, in plugin-neutral terms.
class AttentionNotification {
  const AttentionNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.sessionId,
  });

  /// Stable per session, so a newer event about the same session replaces the
  /// older notification instead of stacking a second one.
  final int id;

  final String title;
  final String body;

  /// Carried as the payload; tapping the notification opens this session.
  final String sessionId;
}

/// Words an attention event the way the desktop's surfaces word it — the
/// inbox's kind labels, never a new phrasing of the same fact.
AttentionNotification notificationFor(CompanionAttentionEvent event) {
  final body = switch (event.kind) {
    CompanionAttentionKind.finished =>
      'Finished a turn — open it when you are ready.',
    CompanionAttentionKind.needsYou => 'Waiting for your approval or input.',
    CompanionAttentionKind.failed => 'The turn ended in error.',
  };
  return AttentionNotification(
    id: stableNotificationId(event.sessionId),
    title: event.sessionTitle,
    body: body,
    sessionId: event.sessionId,
  );
}

/// A deterministic 31-bit id from the session id (Android wants an int; Dart's
/// `String.hashCode` is not stable across runs).
int stableNotificationId(String sessionId) {
  var hash = 0;
  for (final unit in sessionId.codeUnits) {
    hash = 0x1fffffff & (hash + unit);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
  hash ^= hash >> 11;
  return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
}
