import '../../environments/domain/environment_path.dart';

/// Connection state of a device as reported by `adb devices -l`.
enum DeviceConnectionState {
  /// Ready for commands.
  device,

  /// Visible but not yet authorized by the user (USB debugging prompt).
  unauthorized,

  /// Enumerated but not usable (driver/permission problem).
  offline,

  /// Anything adb reports that we do not model explicitly.
  unknown;

  static DeviceConnectionState parse(String raw) => switch (raw.trim()) {
    'device' => DeviceConnectionState.device,
    'unauthorized' => DeviceConnectionState.unauthorized,
    'offline' => DeviceConnectionState.offline,
    _ => DeviceConnectionState.unknown,
  };
}

/// An Android device or running emulator reachable through one adb server.
///
/// The [environmentId] records **which adb saw it**: a Windows adb server and a
/// WSL adb server are different servers with different device lists, so a serial
/// alone does not identify a reachable device (constraints 7 & 8).
class AndroidDevice {
  const AndroidDevice({
    required this.serial,
    required this.environmentId,
    required this.state,
    this.model,
    this.product,
    this.transportId,
  });

  final String serial;
  final String environmentId;
  final DeviceConnectionState state;
  final String? model;
  final String? product;
  final String? transportId;

  /// Emulator serials are always `emulator-<port>`; everything else is physical.
  bool get isEmulator => serial.startsWith('emulator-');

  /// Whether the device can accept commands right now.
  bool get isReady => state == DeviceConnectionState.device;

  /// What to show in the device picker.
  String get displayName => model ?? product ?? serial;

  @override
  bool operator ==(Object other) =>
      other is AndroidDevice &&
      other.serial == serial &&
      other.environmentId == environmentId &&
      other.state == state &&
      other.model == model &&
      other.product == product &&
      other.transportId == transportId;

  @override
  int get hashCode =>
      Object.hash(serial, environmentId, state, model, product, transportId);

  @override
  String toString() => 'AndroidDevice($serial, $state, $displayName)';
}

/// An Android Virtual Device known to the SDK's emulator, and whether it is
/// currently running (matched to a booted [AndroidDevice] by name).
class Avd {
  const Avd({required this.name, this.runningSerial});

  final String name;

  /// Serial of the running emulator for this AVD, or `null` when stopped.
  final String? runningSerial;

  bool get isRunning => runningSerial != null;

  @override
  bool operator ==(Object other) =>
      other is Avd && other.name == name && other.runningSerial == runningSerial;

  @override
  int get hashCode => Object.hash(name, runningSerial);

  @override
  String toString() => 'Avd($name${isRunning ? ' running=$runningSerial' : ''})';
}

/// A located Android SDK, with the tools we actually invoke.
///
/// Every path is an [EnvironmentPath] because an SDK installed on Windows and
/// one installed inside WSL are different installations with different adb
/// servers.
class AndroidSdk {
  const AndroidSdk({
    required this.root,
    required this.adb,
    this.emulator,
  });

  /// SDK root (the directory holding `platform-tools/`).
  final EnvironmentPath root;

  /// `adb` executable — the one tool we cannot work without.
  final EnvironmentPath adb;

  /// `emulator` executable, or `null` when the emulator package is absent.
  final EnvironmentPath? emulator;

  String get environmentId => root.environmentId;

  /// Whether AVDs can be listed and booted.
  bool get canManageAvds => emulator != null;

  @override
  String toString() => 'AndroidSdk(${root.path})';
}
