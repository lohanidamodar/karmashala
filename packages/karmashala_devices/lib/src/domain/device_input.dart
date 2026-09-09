/// A hardware button that can be pressed on a device.
///
/// Values map to Android `KEYCODE_*` names passed to `input keyevent`.
enum DeviceKey {
  back('KEYCODE_BACK'),
  home('KEYCODE_HOME'),
  recents('KEYCODE_APP_SWITCH'),
  power('KEYCODE_POWER'),
  volumeUp('KEYCODE_VOLUME_UP'),
  volumeDown('KEYCODE_VOLUME_DOWN'),
  enter('KEYCODE_ENTER'),
  tab('KEYCODE_TAB'),
  delete('KEYCODE_DEL');

  const DeviceKey(this.keyCode);

  /// The Android keycode name.
  final String keyCode;

  /// Resolves a caller-supplied name ("back", "KEYCODE_BACK", "recents").
  static DeviceKey? parse(String raw) {
    final needle = raw.trim().toLowerCase().replaceAll('keycode_', '');
    for (final key in DeviceKey.values) {
      if (key.name.toLowerCase() == needle) return key;
      if (key.keyCode.toLowerCase().replaceAll('keycode_', '') == needle) {
        return key;
      }
    }
    return switch (needle) {
      'app_switch' || 'appswitch' || 'overview' => DeviceKey.recents,
      'backspace' || 'del' => DeviceKey.delete,
      _ => null,
    };
  }
}

/// The logical size of a device screen, in device pixels.
class DeviceScreenSize {
  const DeviceScreenSize({required this.width, required this.height});

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is DeviceScreenSize &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}
