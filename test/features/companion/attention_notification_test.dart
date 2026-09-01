import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/notifications/attention_notification.dart';
import 'package:flutter_test/flutter_test.dart';

/// The event → notification mapping, unit-tested instead of the plugin: what
/// the phone says, and that a session's newer news replaces its older one.
void main() {
  CompanionAttentionEvent event(CompanionAttentionKind kind) =>
      CompanionAttentionEvent(
        sessionId: 'session-42',
        sessionTitle: 'Fix the login flow',
        kind: kind,
        at: DateTime.utc(2026, 8, 31, 9),
      );

  test('the title is the session; the body is the kind', () {
    final needsYou = notificationFor(event(CompanionAttentionKind.needsYou));
    expect(needsYou.title, 'Fix the login flow');
    expect(needsYou.body, contains('approval'));

    final finished = notificationFor(event(CompanionAttentionKind.finished));
    expect(finished.body, contains('Finished'));

    final failed = notificationFor(event(CompanionAttentionKind.failed));
    expect(failed.body, contains('error'));
  });

  test('tapping opens the session: the payload is the session id', () {
    expect(
      notificationFor(event(CompanionAttentionKind.finished)).sessionId,
      'session-42',
    );
  });

  test('ids are stable per session, so news replaces rather than stacks', () {
    final a = notificationFor(event(CompanionAttentionKind.needsYou));
    final b = notificationFor(event(CompanionAttentionKind.failed));
    expect(a.id, b.id);
    expect(a.id, stableNotificationId('session-42'));
    expect(stableNotificationId('other'), isNot(a.id));
  });

  test('ids fit Android (a positive 31-bit int)', () {
    for (final id in ['a', 'session-42', 'x' * 200]) {
      final value = stableNotificationId(id);
      expect(value, greaterThanOrEqualTo(0));
      expect(value, lessThan(1 << 31));
    }
  });
}
