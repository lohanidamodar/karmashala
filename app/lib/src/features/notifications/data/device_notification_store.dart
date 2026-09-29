import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../core/paths/app_support_directory.dart';

/// A phone's own notification settings, and whether it has asked for the
/// permission, in a file of its own (Stage 3 step 2, open question 4). The
/// server's `notifications.v1` is the desktop's: a phone that wrote it would
/// change the desktop's toasts too.
class DeviceNotificationStore {
  DeviceNotificationStore({Future<Directory> Function()? directory})
    : _directory = directory ?? appSupportDirectory;

  /// A phone notifies in front too, for any session but the one on screen;
  /// the policy's "only while unfocused" is the desktop's.
  static const phoneDefaults = NotificationSettings(onlyWhenUnfocused: false);

  static final _log = AppLogger.named('notifications');

  final Future<Directory> Function() _directory;
  Map<String, Object?>? _kept;
  Future<void> _writing = Future.value();

  Future<File> _file() async =>
      File(p.join((await _directory()).path, 'notifications_device.json'));

  Future<Map<String, Object?>> _read() async {
    final kept = _kept;
    if (kept != null) return kept;
    try {
      final decoded = jsonDecode(await (await _file()).readAsString());
      if (decoded is Map<String, dynamic>) return _kept = decoded;
    } on Object {
      // Nothing kept yet, or unreadable: the defaults stand.
    }
    return _kept = {};
  }

  Future<NotificationSettings> loadSettings() async {
    final kept = await _read();
    if (kept.isEmpty) return phoneDefaults;
    return NotificationSettings.fromJson(
      kept.cast<String, dynamic>(),
    ).copyWith(onlyWhenUnfocused: false);
  }

  Future<void> saveSettings(NotificationSettings settings) => _update({
    'enabled': settings.enabled,
    'notifyWhenFinished': settings.notifyWhenFinished,
    'notifyWhenAttentionNeeded': settings.notifyWhenAttentionNeeded,
  });

  Future<bool> permissionAsked() async =>
      (await _read())['permissionAsked'] == true;

  Future<void> markPermissionAsked() => _update({'permissionAsked': true});

  /// One write at a time, each over the last, so two changes close together
  /// never leave the older on disk.
  Future<void> _update(Map<String, Object?> changes) =>
      _writing = _writing.then((_) async {
        final next = {...await _read(), ...changes};
        _kept = next;
        try {
          final file = await _file();
          await file.parent.create(recursive: true);
          await file.writeAsString(jsonEncode(next), flush: true);
        } on Object catch (e) {
          _log.warning('Keeping the phone notification settings failed: $e');
        }
      });
}

final deviceNotificationStoreProvider = Provider<DeviceNotificationStore>(
  (ref) => DeviceNotificationStore(),
);
