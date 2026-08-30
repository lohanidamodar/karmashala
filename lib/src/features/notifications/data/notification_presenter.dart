import '../domain/notification_request.dart';

/// Delivers a notification to the operating system.
///
/// Abstracted so the policy and the watcher can be tested without a desktop,
/// and so a platform we do not deliver on yet degrades to silence rather than
/// to an error.
abstract interface class NotificationPresenter {
  /// Whether this presenter can actually put something on screen. False means
  /// [show] is a no-op — useful for telling the user the truth in the UI.
  bool get isSupported;

  Future<void> show(NotificationRequest request);

  void dispose();
}

/// The presenter used everywhere we cannot deliver an OS notification.
class NoopNotificationPresenter implements NotificationPresenter {
  const NoopNotificationPresenter();

  @override
  bool get isSupported => false;

  @override
  Future<void> show(NotificationRequest request) async {}

  @override
  void dispose() {}
}
