import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_notifications/toasts.dart';

/// Desktop OS notifications, via `local_notifier`. Windows toasts need the app
/// to own a Start Menu shortcut with its AUMID; macOS and Linux are untested.
class DesktopNotificationPresenter implements NotificationPresenter {
  DesktopNotificationPresenter({
    this.onActivated,
    this.onAction,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('notifications');

  /// How many delivered notifications to keep alive. `local_notifier` registers
  /// every [LocalNotification] as a listener and never drops it.
  static const _keepAlive = 8;

  static bool get isSupportedHere =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Called with the payload of a clicked notification, if it carried one.
  final void Function(NotificationPayload payload)? onActivated;

  /// Called with the payload and the index of a pressed button, for a
  /// request that carried [NotificationRequest.actions]. `local_notifier`
  /// draws them on Windows (WinToast) and macOS; where it cannot, the toast
  /// simply has none and a click still opens the session.
  final void Function(NotificationPayload payload, int action)? onAction;

  final AppLogger _logger;
  final Queue<LocalNotification> _delivered = Queue();

  bool _ready = false;
  bool _unavailable = false;

  @override
  bool get isSupported => isSupportedHere && !_unavailable;

  Future<bool> _ensureReady() async {
    if (_ready) return true;
    if (_unavailable || !isSupportedHere) return false;
    try {
      await localNotifier.setup(appName: 'Karmashala');
      _ready = true;
      return true;
    } catch (error, stack) {
      _unavailable = true;
      _logger.warning('Desktop notifications unavailable.', error, stack);
      return false;
    }
  }

  @override
  Future<void> show(NotificationRequest request) async {
    if (!await _ensureReady()) return;
    try {
      final payload = NotificationPayload.decode(request.payload);
      final notification = LocalNotification(
        title: request.title,
        body: request.body,
      );
      if (payload != null && onActivated != null) {
        notification.onClick = () => onActivated!(payload);
      }
      final act = onAction;
      if (payload != null && act != null && request.actions.isNotEmpty) {
        notification
          ..actions = [
            for (final label in request.actions)
              LocalNotificationAction(text: label),
          ]
          ..onClickAction = (index) => act(payload, index);
      }
      await notification.show();
      _retire(notification);
    } catch (error, stack) {
      _logger.warning('Could not show a notification.', error, stack);
    }
  }

  /// Tracks [shown] and releases the oldest once the window is full, which both
  /// unregisters its listener and dismisses a notification long since replaced.
  void _retire(LocalNotification shown) {
    _delivered.addLast(shown);
    while (_delivered.length > _keepAlive) {
      final oldest = _delivered.removeFirst();
      try {
        oldest.destroy();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    for (final notification in _delivered) {
      try {
        localNotifier.removeListener(notification);
      } catch (_) {}
    }
    _delivered.clear();
    _ready = false;
  }
}
