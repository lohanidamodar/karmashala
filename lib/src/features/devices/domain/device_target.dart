import 'android_device.dart';
import 'ios_simulator.dart';

/// The two kinds of thing this app can drive.
///
/// Not a feature flag and not a capability: a *fact* about a device, used to
/// pick the driver and to name the coordinate space in a message. What a
/// device can actually do is [DeviceCapability] in `device_driver.dart`, and
/// the two are deliberately separate — a simulator on a build with no
/// WebDriverAgent is still iOS, it just cannot be tapped.
enum DevicePlatform {
  android('Android'),
  ios('iOS');

  const DevicePlatform(this.label);

  final String label;
}

/// [id] made safe as one component of a **host** filename.
///
/// A device attached over Wi-Fi identifies itself as `HOST:PORT` rather than by
/// hardware serial, and on Windows a colon in a filename does not fail — it
/// opens an *alternate data stream*, so `adb pull` writes somewhere nothing
/// reads back and the failure looks like an empty screenshot. Everything
/// outside `[A-Za-z0-9._-]` becomes `-`, which leaves a hardware serial and an
/// `emulator-<port>` untouched.
String fileSafeDeviceId(String id) =>
    id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');

/// One device this app knows about: an attached Android device, an Android
/// emulator, or an iOS Simulator.
///
/// ## Why the two live behind one type
///
/// The `device_*` MCP tools took an Android serial and nothing else, and the
/// obvious way to add simulators was a `simulator_*` family beside them. That
/// would have doubled the vocabulary an agent has to hold — `device_tap` and
/// `simulator_tap` do the same thing to the same kind of object — and worse, it
/// would have made "which verb do I call" a question the caller must answer
/// *before* it knows what kind of device it has. The identifiers give nothing
/// away: `emulator-5554` and `70592006-11CD-…` are both just strings out of
/// `list_devices`.
///
/// So the id is the discriminator, this type carries the answer, and the
/// dispatch happens once — in `DeviceFleet.driverFor`, not in every caller.
sealed class DeviceTarget {
  const DeviceTarget();

  /// What `list_devices` printed and what a caller passes back: an adb serial
  /// or a simulator udid.
  String get id;

  /// A human name for messages — never used to address the device.
  String get label;

  DevicePlatform get platform;

  /// Whether it can be driven right now. An Android device that is
  /// `unauthorized`, or a simulator that is shut down, is a real row in a
  /// device listing and not a mistake to hide — but it cannot be tapped.
  bool get isReady;

  /// Why it is not ready, in the caller's terms, or null when it is.
  String? get notReadyReason;

  /// One line for an error listing: enough to choose from, and no more.
  String get summary => '$id ($label, ${platform.label})';

  /// [id], safe to put in a host filename — see [fileSafeDeviceId].
  String get fileSafeId => fileSafeDeviceId(id);
}

final class AndroidTarget extends DeviceTarget {
  const AndroidTarget(this.device);

  final AndroidDevice device;

  @override
  String get id => device.serial;

  @override
  String get label => device.displayName;

  @override
  DevicePlatform get platform => DevicePlatform.android;

  @override
  bool get isReady => device.isReady;

  @override
  String? get notReadyReason => device.isReady
      ? null
      : device.state == DeviceConnectionState.unauthorized
      ? '${device.serial} is unauthorized — accept the USB debugging prompt on '
            'the device.'
      : '${device.serial} is ${device.state.name}, not ready.';
}

final class SimulatorTarget extends DeviceTarget {
  const SimulatorTarget(this.simulator);

  final IosSimulator simulator;

  @override
  String get id => simulator.udid;

  @override
  String get label => simulator.displayName;

  @override
  DevicePlatform get platform => DevicePlatform.ios;

  @override
  bool get isReady => simulator.state.isReady;

  @override
  String? get notReadyReason {
    if (simulator.state.isReady) return null;
    if (!simulator.isAvailable) {
      return '${simulator.displayName} has no installed runtime, so it cannot '
          'be booted. Install ${simulator.runtimeName} in Xcode, or pick '
          'another simulator.';
    }
    return switch (simulator.state) {
      SimulatorState.shutdown =>
        '${simulator.displayName} (${simulator.udid}) is shut down. Boot it '
            'with device_boot first.',
      SimulatorState.booting =>
        '${simulator.displayName} is still booting. device_boot waits for it '
            'properly; a command sent now would be refused by simctl.',
      SimulatorState.shuttingDown =>
        '${simulator.displayName} is shutting down.',
      _ =>
        '${simulator.displayName} is in a state simctl called '
            '"${simulator.state.name}", which this build does not know how to '
            'drive.',
    };
  }
}
