import 'dart:typed_data';

/// Something done to a device, reported to whoever is recording. It exists so a
/// verification run watches the *existing* `AdbService` rather than a second,
/// recording copy that would drift from it.
class DeviceAction {
  const DeviceAction({
    required this.verb,
    required this.serial,
    required this.summary,
    this.detail,
    this.ok = true,
    this.png,
    this.text,
  });

  /// What was done: `launch`, `tap`, `swipe`, `type`, `key`, `screenshot`,
  /// `uiDump`, `logcat`.
  final String verb;

  final String serial;

  /// One line: the action and its target.
  final String summary;

  /// Anything longer — the failure, the tree, the log slice.
  final String? detail;

  final bool ok;

  /// An image this action produced. Handed over rather than written here:
  /// where evidence is stored is not adb's business.
  final Uint8List? png;

  /// A text payload worth keeping as a file — a UI tree, a log slice.
  final String? text;

  DeviceAction failed(Object error) => DeviceAction(
    verb: verb,
    serial: serial,
    summary: summary,
    detail: '$error',
    ok: false,
  );
}

/// Where [DeviceAction]s go. Null means nobody is recording.
typedef DeviceActionSink = void Function(DeviceAction action);
