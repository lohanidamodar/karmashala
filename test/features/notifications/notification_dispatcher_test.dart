import 'package:chitragupta/src/features/notifications/application/notification_dispatcher.dart';
import 'package:chitragupta/src/features/notifications/data/notification_presenter.dart';
import 'package:chitragupta/src/features/notifications/domain/agent_session_key.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_policy.dart';
import 'package:chitragupta/src/features/notifications/domain/notification_request.dart';
import 'package:chitragupta/src/features/notifications/domain/watched_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingPresenter implements NotificationPresenter {
  final List<NotificationRequest> shown = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> show(NotificationRequest request) async => shown.add(request);

  @override
  void dispose() {}
}

PendingNotification _event(
  String id, [
  NotificationReason reason = NotificationReason.finished,
]) => PendingNotification(
  session: WatchedSession(
    key: AgentSessionKey('claudeCode', id),
    label: 'Session $id',
    openId: 'row-$id',
    imported: true,
  ),
  reason: reason,
);

void main() {
  late _RecordingPresenter presenter;

  setUp(() => presenter = _RecordingPresenter());

  test('a burst inside one window is a single interruption', () async {
    final dispatcher = NotificationDispatcher(
      presenter: presenter,
      window: const Duration(milliseconds: 30),
    );
    addTearDown(dispatcher.dispose);

    dispatcher
      ..add(_event('a'))
      ..add(_event('b'))
      ..add(_event('c'));

    await dispatcher.flush();

    expect(presenter.shown, hasLength(1));
    expect(presenter.shown.single.title, '3 agents finished');
  });

  test('the window closes on its own', () async {
    final dispatcher = NotificationDispatcher(
      presenter: presenter,
      window: const Duration(milliseconds: 20),
    );
    addTearDown(dispatcher.dispose);

    dispatcher.add(_event('a'));
    expect(presenter.shown, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(presenter.shown, hasLength(1));
  });

  test('events after a flush start a new window', () async {
    final dispatcher = NotificationDispatcher(
      presenter: presenter,
      window: const Duration(milliseconds: 30),
    );
    addTearDown(dispatcher.dispose);

    dispatcher.add(_event('a'));
    await dispatcher.flush();
    dispatcher.add(_event('b'));
    await dispatcher.flush();

    expect(presenter.shown, hasLength(2));
  });

  group('the deadline', () {
    // The audit's other half of "hooks are the primary path": `b8d22af` made a
    // hook reach the registry, the tray and the inbox as it lands, and left it
    // waiting the full coalescing window for the toast — the one surface the
    // user is actually looking away from.

    test('an approval is not held for a finished turn\'s window', () async {
      final dispatcher = NotificationDispatcher(
        presenter: presenter,
        window: const Duration(seconds: 5),
        urgentWindow: const Duration(milliseconds: 20),
      );
      addTearDown(dispatcher.dispose);

      // The finished turn opens a five-second window; the approval lands inside
      // it and must not inherit it.
      dispatcher
        ..add(_event('a'))
        ..add(_event('b', NotificationReason.needsInput));

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        presenter.shown,
        hasLength(1),
        reason: 'the earliest deadline pending is the one that fires',
      );
      // Still one interruption: the deadline moved, the coalescing did not.
      expect(presenter.shown.single.body, contains('Session b'));
      expect(presenter.shown.single.body, contains('Session a'));
    });

    test('a finished turn cannot push an approval out', () async {
      final dispatcher = NotificationDispatcher(
        presenter: presenter,
        window: const Duration(seconds: 5),
        urgentWindow: const Duration(milliseconds: 20),
      );
      addTearDown(dispatcher.dispose);

      // The other order: the short deadline is set first, and the long one
      // arriving after it must leave it alone.
      dispatcher
        ..add(_event('a', NotificationReason.needsInput))
        ..add(_event('b'));

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(presenter.shown, hasLength(1));
    });

    test('a burst of approvals is still one interruption', () async {
      final dispatcher = NotificationDispatcher(
        presenter: presenter,
        urgentWindow: const Duration(milliseconds: 40),
      );
      addTearDown(dispatcher.dispose);

      dispatcher
        ..add(_event('a', NotificationReason.needsInput))
        ..add(_event('b', NotificationReason.failed))
        ..add(_event('c', NotificationReason.needsInput));

      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(presenter.shown, hasLength(1));
    });

    test('the window a reason waits for is the one it asked for', () {
      final dispatcher = NotificationDispatcher(presenter: presenter);
      addTearDown(dispatcher.dispose);

      for (final reason in NotificationReason.values) {
        expect(
          dispatcher.windowFor(reason),
          reason == NotificationReason.finished
              ? dispatcher.window
              : dispatcher.urgentWindow,
          reason: '$reason',
        );
      }
      expect(dispatcher.urgentWindow, lessThan(dispatcher.window));
    });
  });

  test('flushing nothing shows nothing', () async {
    final dispatcher = NotificationDispatcher(presenter: presenter);
    addTearDown(dispatcher.dispose);

    await dispatcher.flush();

    expect(presenter.shown, isEmpty);
  });

  test('disposing drops what was still buffered', () async {
    final dispatcher = NotificationDispatcher(
      presenter: presenter,
      window: const Duration(milliseconds: 20),
    );

    dispatcher.add(_event('a'));
    dispatcher.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(presenter.shown, isEmpty);
  });

  test('the no-op presenter reports that it cannot deliver', () {
    expect(const NoopNotificationPresenter().isSupported, isFalse);
  });
}
