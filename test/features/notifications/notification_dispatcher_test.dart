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

PendingNotification _event(String id) => PendingNotification(
  session: WatchedSession(
    key: AgentSessionKey('claudeCode', id),
    label: 'Session $id',
    openId: 'row-$id',
    imported: true,
  ),
  reason: NotificationReason.finished,
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
