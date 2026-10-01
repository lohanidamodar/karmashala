import 'device_driver.dart' show DeviceRefusal;

/// Which way up the screen is held. Android's `user_rotation` values in
/// declaration order after [auto], which hands the choice back to the sensor.
enum DeviceRotation {
  auto,
  portrait,
  landscape,
  reversePortrait,
  reverseLandscape;

  static DeviceRotation? fromName(String? name) {
    for (final value in values) {
      if (value.name.toLowerCase() == name?.trim().toLowerCase()) return value;
    }
    return null;
  }
}

/// A network to pretend to be on. Only an emulator can be throttled; a phone
/// and a simulator can at most be cut off, and the simulator not even that.
enum NetworkProfile {
  full,
  offline,
  lte,
  umts,
  edge,
  gprs;

  bool get isThrottle =>
      this != NetworkProfile.full && this != NetworkProfile.offline;

  static NetworkProfile? fromName(String? name) {
    for (final value in values) {
      if (value.name == name?.trim().toLowerCase()) return value;
    }
    return null;
  }
}

/// Something about the device an app under test reads from outside itself,
/// changed by a driver: it says what it did, or throws [DeviceRefusal].
sealed class DeviceStateChange {
  const DeviceStateChange();

  /// The argument this change answers to, for a per-setting report.
  String get key;
}

final class AppearanceChange extends DeviceStateChange {
  const AppearanceChange({required this.dark});

  final bool dark;

  @override
  String get key => 'appearance';
}

final class FontScaleChange extends DeviceStateChange {
  FontScaleChange(this.scale) {
    if (scale.isNaN || scale < 0.5 || scale > 3.5) {
      throw DeviceRefusal(
        'fontScale $scale is outside 0.5–3.5. 1.0 is the default; 1.3 is '
        'Android\'s "largest" without accessibility sizes.',
      );
    }
  }

  final double scale;

  @override
  String get key => 'fontScale';
}

final class LocaleChange extends DeviceStateChange {
  LocaleChange(String tag, {this.appId})
    : tag = tag.trim().replaceAll('_', '-') {
    if (!_localeTag.hasMatch(this.tag)) {
      throw DeviceRefusal(
        'locale "$tag" is not a BCP 47 tag like "fr", "fr-FR" or "zh-Hans-CN".',
      );
    }
    if (appId != null) requireAppId(appId!);
  }

  final String tag;

  /// The app to set it for, where the platform can only do it per app.
  final String? appId;

  @override
  String get key => 'locale';
}

final class RotationChange extends DeviceStateChange {
  const RotationChange(this.rotation);

  final DeviceRotation rotation;

  @override
  String get key => 'rotation';
}

final class NetworkChange extends DeviceStateChange {
  const NetworkChange(this.profile);

  final NetworkProfile profile;

  @override
  String get key => 'network';
}

final class PermissionChange extends DeviceStateChange {
  PermissionChange({
    required this.appId,
    required String permission,
    required this.grant,
  }) : permission = permission.trim() {
    requireAppId(appId);
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$').hasMatch(this.permission)) {
      throw DeviceRefusal(
        'permission "$permission" is not a permission name, such as CAMERA, '
        'android.permission.POST_NOTIFICATIONS or (iOS) photos.',
      );
    }
  }

  final String appId;
  final String permission;
  final bool grant;

  @override
  String get key => 'permission';
}

final class ClearAppDataChange extends DeviceStateChange {
  ClearAppDataChange(this.appId) {
    requireAppId(appId);
  }

  final String appId;

  @override
  String get key => 'clearAppData';
}

final class OpenUrlChange extends DeviceStateChange {
  OpenUrlChange(String url, {this.appId}) : url = url.trim() {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:\S+$').hasMatch(this.url)) {
      throw DeviceRefusal(
        'url "$url" has no scheme. Give https://… or a custom scheme such as '
        'myapp://path.',
      );
    }
    if (appId != null) requireAppId(appId!);
  }

  final String url;
  final String? appId;

  @override
  String get key => 'url';
}

final _localeTag = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

/// Refuses anything that is not an application or bundle id, because these
/// reach a device shell as words.
void requireAppId(String appId) {
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$').hasMatch(appId)) {
    throw DeviceRefusal(
      'appId "$appId" is not an application or bundle id like com.example.app.',
    );
  }
}
