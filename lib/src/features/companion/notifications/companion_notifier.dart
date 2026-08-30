import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'attention_notification.dart';

/// Shows attention notifications on the phone — the only file that touches
/// `flutter_local_notifications`. Initialised solely by the companion
/// bootstrap, so a desktop build never loads the plugin.
class CompanionNotifier {
  CompanionNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// Wires the plugin and the tap handler. [onOpenSession] receives the
  /// session id a tapped notification carries.
  Future<void> initialize({
    required void Function(String sessionId) onOpenSession,
  }) async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    _ready =
        await _plugin.initialize(
          settings,
          onDidReceiveNotificationResponse: (response) {
            final payload = response.payload;
            if (payload != null && payload.isNotEmpty) onOpenSession(payload);
          },
        ) ??
        false;
    // Android 13+ gates POST_NOTIFICATIONS behind a runtime prompt.
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> show(AttentionNotification notification) async {
    if (!_ready) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'attention',
        'Attention',
        channelDescription: 'A session finished, failed, or needs you.',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      notification.id,
      notification.title,
      notification.body,
      details,
      payload: notification.sessionId,
    );
  }
}
