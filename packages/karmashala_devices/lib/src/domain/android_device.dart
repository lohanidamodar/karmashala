import 'package:agent_cli/process.dart';

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

/// An Android device or running emulator reachable through one adb server. The
/// [environmentId] records **which adb saw it**: a Windows adb server and a WSL
/// one have different device lists, so a serial alone does not identify one.
class AndroidDevice {
  const AndroidDevice({
    required this.serial,
    required this.environmentId,
    required this.state,
    this.model,
    this.product,
    this.transportId,
    this.otherSerials = const [],
  });

  final String serial;
  final String environmentId;
  final DeviceConnectionState state;
  final String? model;
  final String? product;
  final String? transportId;

  /// The serials of this same device's other transports — its cable and its
  /// wireless adb — listed as one by [mergeDeviceTransports].
  final List<String> otherSerials;

  /// Whether [serial] reaches this device by any of its transports.
  bool answersTo(String? serial) =>
      serial != null &&
      (serial == this.serial || otherSerials.contains(serial));

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
      other.transportId == transportId &&
      _sameSerials(other.otherSerials, otherSerials);

  @override
  int get hashCode => Object.hash(
    serial,
    environmentId,
    state,
    model,
    product,
    transportId,
    Object.hashAll(otherSerials),
  );

  static bool _sameSerials(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  AndroidDevice _alsoOver(AndroidDevice other) => AndroidDevice(
    serial: serial,
    environmentId: environmentId,
    state: state,
    model: model ?? other.model,
    product: product ?? other.product,
    transportId: transportId,
    otherSerials: [...otherSerials, other.serial, ...other.otherSerials],
  );

  @override
  String toString() => 'AndroidDevice($serial, $state, $displayName)';
}

/// The serial wireless adb's mDNS name carries:
/// `adb-<serial>-<suffix>._adb-tls-connect._tcp`.
final RegExp _mdnsSerial = RegExp(r'^adb-(.+)-[^-]+\._adb-tls-connect\._tcp$');

/// `host:port`: a transport `adb connect` opened, which names no serial.
final RegExp _hostPort = RegExp(r'^(\[[^\]]+\]|[^:\s]+):\d+$');

bool _isWireless(String serial) =>
    _mdnsSerial.hasMatch(serial) || _hostPort.hasMatch(serial);

/// **[devices] with each phone listed once**, whichever transports reach it.
/// A wireless transport joins the cabled device whose serial its mDNS name
/// carries, or — naming none — the one cabled device of its model on the same
/// adb server. Two candidates are never guessed between. The ready transport
/// answers; the cable when both are.
List<AndroidDevice> mergeDeviceTransports(List<AndroidDevice> devices) {
  final cabled = [
    for (final device in devices)
      if (!device.isEmulator && !_isWireless(device.serial)) device,
  ];
  AndroidDevice? cableFor(AndroidDevice wireless) {
    final named = _mdnsSerial.firstMatch(wireless.serial)?.group(1);
    if (named != null) {
      for (final cable in cabled) {
        if (cable.serial == named &&
            cable.environmentId == wireless.environmentId) {
          return cable;
        }
      }
    }
    final model = wireless.model;
    if (model == null) return null;
    final sameModel = [
      for (final cable in cabled)
        if (cable.model == model &&
            cable.environmentId == wireless.environmentId)
          cable,
    ];
    final wirelessOfModel = devices.where(
      (d) =>
          _isWireless(d.serial) &&
          d.model == model &&
          d.environmentId == wireless.environmentId,
    );
    return sameModel.length == 1 && wirelessOfModel.length == 1
        ? sameModel.single
        : null;
  }

  final joined = <AndroidDevice, AndroidDevice>{};
  for (final device in devices) {
    if (!_isWireless(device.serial)) continue;
    final cable = cableFor(device);
    if (cable == null || joined.containsKey(cable)) continue;
    joined[cable] = device;
  }
  if (joined.isEmpty) return devices;
  final absorbed = joined.values.toSet();
  return [
    for (final device in devices)
      if (!absorbed.contains(device))
        if (joined[device] case final wireless?)
          device.isReady || !wireless.isReady
              ? device._alsoOver(wireless)
              : wireless._alsoOver(device)
        else
          device,
  ];
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
      other is Avd &&
      other.name == name &&
      other.runningSerial == runningSerial;

  @override
  int get hashCode => Object.hash(name, runningSerial);

  @override
  String toString() =>
      'Avd($name${isRunning ? ' running=$runningSerial' : ''})';
}

/// A located Android SDK, with the tools we actually invoke. Every path is an
/// [EnvironmentPath]: a Windows SDK and a WSL one are different installations.
class AndroidSdk {
  const AndroidSdk({required this.root, required this.adb, this.emulator});

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
