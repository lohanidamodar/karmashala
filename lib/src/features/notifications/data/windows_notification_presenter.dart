import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/notification_request.dart';
import 'notification_presenter.dart';

/// Windows toast notifications, via the Windows implementation of
/// `flutter_local_notifications`.
///
/// The plugin registers the app's AUMID under `HKCU\Software\Classes\
/// AppUserModelId` on first use, which is what lets an unpackaged desktop app
/// raise toasts at all — no installer or Start Menu shortcut is needed.
///
/// Everything here is best-effort: the plugin loads a native DLL, so a host
/// without it (a `flutter test` run, a stripped build) must degrade to silence
/// rather than take the app down. The failure is logged once.
class WindowsNotificationPresenter implements NotificationPresenter {
  WindowsNotificationPresenter({this.onActivated, AppLogger? logger})
    : _logger = logger ?? AppLogger.named('notifications');

  /// The AUMID Windows files our toasts under. Changing it makes Windows treat
  /// the app as a different sender and forget the user's per-app notification
  /// preferences, so it is a constant, not a setting.
  static const appUserModelId = 'PopupBits.Chitragupta';

  /// Identifies the COM activator the plugin registers for toast clicks.
  static const activationGuid = 'cc1db019-7765-4f7e-b4a0-0202ff52c89e';

  static bool get isSupportedHere => !kIsWeb && Platform.isWindows;

  /// Called with the payload of a clicked toast, if it carried one.
  final void Function(NotificationPayload payload)? onActivated;

  final AppLogger _logger;

  FlutterLocalNotificationsWindows? _plugin;
  bool _ready = false;
  bool _unavailable = false;
  int _nextId = 1;

  @override
  bool get isSupported => isSupportedHere && !_unavailable;

  /// Creates and initializes the plugin on first use.
  ///
  /// Construction itself opens the native DLL, so it happens inside the guard
  /// rather than in a field initializer.
  Future<bool> _ensureReady() async {
    if (_ready) return true;
    if (_unavailable || !isSupportedHere) return false;
    try {
      final plugin = FlutterLocalNotificationsWindows();
      final ok = await plugin.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'Chitragupta',
          appUserModelId: appUserModelId,
          guid: activationGuid,
        ),
        // The response type lives in the platform interface, which this package
        // does not re-export; an inline closure infers it without naming it.
        onDidReceiveNotificationResponse: (response) =>
            _handleActivation(response.payload),
      );
      if (!ok) {
        _unavailable = true;
        _logger.warning('Windows notifications declined to initialize.');
        return false;
      }
      _plugin = plugin;
      _ready = true;
      return true;
    } catch (error, stack) {
      _unavailable = true;
      _logger.warning('Windows notifications unavailable.', error, stack);
      return false;
    }
  }

  void _handleActivation(String? raw) {
    final payload = NotificationPayload.decode(raw);
    if (payload != null) onActivated?.call(payload);
  }

  @override
  Future<void> show(NotificationRequest request) async {
    if (!await _ensureReady()) return;
    try {
      await _plugin!.show(
        id: _nextId++,
        title: request.title,
        body: request.body,
        payload: request.payload,
      );
    } catch (error, stack) {
      _logger.warning('Could not show a notification.', error, stack);
    }
  }

  @override
  void dispose() {
    try {
      _plugin?.dispose();
    } catch (_) {}
    _plugin = null;
    _ready = false;
  }
}
