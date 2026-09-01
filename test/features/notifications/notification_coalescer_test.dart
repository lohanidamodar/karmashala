import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/notification_policy.dart';
import 'package:karmashala/src/features/notifications/domain/notification_request.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _coalescer = NotificationCoalescer();

PendingNotification _event(
  String id,
  NotificationReason reason, {
  String? label,
  bool imported = true,
}) => PendingNotification(
  session: WatchedSession(
    key: AgentSessionKey('claudeCode', id),
    label: label ?? 'Session $id',
    openId: 'row-$id',
    imported: imported,
  ),
  reason: reason,
);

void main() {
  test('nothing to say produces no notification', () {
    expect(_coalescer.summarize(const []), isNull);
  });

  test('one event names the session and carries where to open it', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.needsInput, label: 'Fix login'),
    ])!;

    expect(request.title, 'Agent needs your approval');
    expect(request.body, 'Fix login');
    final payload = NotificationPayload.decode(request.payload)!;
    expect(payload.openId, 'row-a');
    expect(payload.imported, isTrue);
  });

  test('three agents finishing at once are one notification', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished, label: 'One'),
      _event('b', NotificationReason.finished, label: 'Two'),
      _event('c', NotificationReason.finished, label: 'Three'),
    ])!;

    expect(request.title, '3 agents finished');
    expect(request.body, 'One · Two · Three');
  });

  test('several sessions all waiting say so', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.needsInput, label: 'One'),
      _event('b', NotificationReason.failed, label: 'Two'),
    ])!;

    expect(request.title, '2 sessions need you');
  });

  test('a mixed burst does not claim they all need you', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished),
      _event('b', NotificationReason.needsInput),
    ])!;

    expect(request.title, '2 agent updates');
  });

  test('a long list names a few and counts the rest', () {
    final request = _coalescer.summarize([
      for (final id in ['a', 'b', 'c', 'd', 'e'])
        _event(id, NotificationReason.finished, label: id.toUpperCase()),
    ])!;

    expect(request.title, '5 agents finished');
    expect(request.body, 'A · B · C · +2 more');
  });

  test('a summary does not guess which session to open', () {
    final request = _coalescer.summarize([
      _event('a', NotificationReason.finished),
      _event('b', NotificationReason.finished),
    ])!;

    expect(request.payload, isNull);
  });

  test(
    'one session moving twice is one line, described by its latest state',
    () {
      final request = _coalescer.summarize([
        _event('a', NotificationReason.finished, label: 'Only'),
        _event('a', NotificationReason.needsInput, label: 'Only'),
      ])!;

      expect(request.title, 'Agent needs your approval');
      expect(request.body, 'Only');
    },
  );

  group('payload encoding', () {
    test('round-trips both session kinds', () {
      for (final imported in [true, false]) {
        final encoded = NotificationPayload(
          openId: 'abc:def',
          imported: imported,
        ).encode();
        final decoded = NotificationPayload.decode(encoded)!;
        expect(decoded.openId, 'abc:def');
        expect(decoded.imported, imported);
      }
    });

    test('rejects anything it did not write', () {
      for (final raw in [null, '', 'abc', 'other:abc', ':abc', 'native:']) {
        expect(NotificationPayload.decode(raw), isNull, reason: 'raw=$raw');
      }
    });
  });
}
