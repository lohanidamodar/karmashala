import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_notifications/toasts.dart';

/// A phone's notifications, via `flutter_local_notifications`, shown only
/// while the app's process runs: there is no push (Stage 3 step 2).
///
/// One notification per session: its id is drawn from the session's open id,
/// so the next one for that session replaces it, and [withdraw] takes it
/// down. A tap hands [onActivated] the payload. There are no Allow or Deny
/// actions here (open question 3): a tap opens the session, and the dock
/// answers.
class PhoneNotificationPresenter implements NotificationPresenter {
  PhoneNotificationPresenter({
    this.onActivated,
    FlutterLocalNotificationsPlugin? plugin,
    AppLogger? logger,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _logger = logger ?? AppLogger.named('notifications');

  /// The companion's channel id, kept so a phone moved off the companion keeps
  /// what the owner set on it. Android fixes a channel's importance when it is
  /// created, so a channel silenced there stays silent: the settings page's
  /// link to the system settings is the way out.
  static const channelId = 'attention';

  /// Monochrome: Android draws a full-colour icon as a white square.
  static const _icon = '@drawable/ic_stat_karmashala';

  static bool get isSupportedHere =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// The launch a tapped notification started is read once per process, not
  /// again by the session a later switch of server opens.
  static bool _launchTaken = false;

  final void Function(NotificationPayload payload)? onActivated;

  final FlutterLocalNotificationsPlugin _plugin;
  final AppLogger _logger;
  Future<bool>? _ready;
  bool _disposed = false;

  @override
  bool get isSupported => isSupportedHere;

  /// Sets the plugin up and takes over its tap. Asks for nothing: the
  /// permission is asked once, after the first pairing ([requestPermission]).
  Future<bool> initialize() => _ready ??= _initialize();

  Future<bool> _initialize() async {
    if (!isSupportedHere) return false;
    try {
      final ready = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(_icon),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _tapped,
      );
      return ready ?? false;
    } on Object catch (error, stack) {
      _logger.warning('Phone notifications unavailable.', error, stack);
      return false;
    }
  }

  void _tapped(NotificationResponse response) {
    if (_disposed) return;
    final payload = NotificationPayload.decode(response.payload);
    if (payload != null) onActivated?.call(payload);
  }

  /// The session a tapped notification started the app for, once per process;
  /// null when the app was started any other way.
  Future<NotificationPayload?> takeLaunchPayload() async {
    if (_launchTaken || !await initialize()) return null;
    _launchTaken = true;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      return NotificationPayload.decode(details.notificationResponse?.payload);
    } on Object catch (error) {
      _logger.warning('Reading the notification launch failed: $error');
      return null;
    }
  }

  @override
  Future<void> show(NotificationRequest request) async {
    if (_disposed || !await initialize()) return;
    final payload = NotificationPayload.decode(request.payload);
    try {
      await _plugin.show(
        id: payload == null
            ? notificationIdFor('app:${request.title}')
            : notificationIdFor(payload.openId),
        title: request.title,
        body: request.body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Attention',
            channelDescription: 'A session finished, failed, or needs you.',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: request.payload,
      );
    } on Object catch (error, stack) {
      _logger.warning('Could not show a notification.', error, stack);
    }
  }

  /// Takes down [openId]'s notification, if one is up.
  Future<void> withdraw(String openId) async {
    if (!await initialize()) return;
    try {
      await _plugin.cancel(id: notificationIdFor(openId));
    } on Object catch (error) {
      _logger.warning('Withdrawing the notification for $openId failed: $error');
    }
  }

  /// Asks the OS to let the app notify: Android 13's runtime prompt, iOS's
  /// alert, badge and sound, asked explicitly. True when allowed.
  Future<bool> requestPermission() async {
    if (!await initialize()) return false;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return await ios?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    } on Object catch (error) {
      _logger.warning('Asking for the notification permission failed: $error');
      return false;
    }
  }

  /// Whether the OS lets the app notify now; null when it cannot be read.
  Future<bool?> permissionGranted() async {
    if (!await initialize()) return null;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) return await android.areNotificationsEnabled();
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return (await ios?.checkPermissions())?.isEnabled;
    } on Object catch (error) {
      _logger.warning('Reading the notification permission failed: $error');
      return null;
    }
  }

  /// The app's page in the system's notification settings.
  Future<void> openSystemSettings() async {
    if (!await initialize()) return;
    try {
      await (_plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.openAppNotificationSettings() ??
              _plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.openAppNotificationSettings());
    } on Object catch (error) {
      _logger.warning('Opening the notification settings failed: $error');
    }
  }

  /// Notifications already shown stay: they outlive a switch of server, and
  /// a tap then opens the app on whichever server is in use.
  @override
  void dispose() => _disposed = true;
}

/// A deterministic 31-bit id for [key] — Android wants an int, and Dart's
/// `String.hashCode` is not stable across runs. The companion's, so an id it
/// used names the same session here.
int notificationIdFor(String key) {
  var hash = 0;
  for (final unit in key.codeUnits) {
    hash = 0x1fffffff & (hash + unit);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
  hash ^= hash >> 11;
  return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
}
