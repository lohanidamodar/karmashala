import 'android_device.dart';
import 'ios_simulator.dart';

/// The two kinds of thing this app can drive. A *fact* about a device, used to
/// pick the driver and name the coordinate space — what it can actually do is
/// [DeviceCapability], and a simulator with no WebDriverAgent is still iOS.
enum DevicePlatform {
  android('Android'),
  ios('iOS');

  const DevicePlatform(this.label);

  final String label;
}

/// [id] made safe as one component of a **host** filename. A Wi-Fi device is
/// `HOST:PORT`, and on Windows a colon opens an alternate data stream, so the
/// write succeeds and the screenshot reads back empty.
String fileSafeDeviceId(String id) =>
    id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');

/// One device this app knows about: an attached Android device, an emulator, or
/// an iOS Simulator. One type rather than a `simulator_*` tool family, because
/// the identifiers give nothing away — `emulator-5554` and a udid are both just
/// strings — so the id is the discriminator and the dispatch happens once.
sealed class DeviceTarget {
  const DeviceTarget();

  /// What `list_devices` printed and what a caller passes back: an adb serial
  /// or a simulator udid.
  String get id;

  /// A human name for messages — never used to address the device.
  String get label;

  DevicePlatform get platform;

  /// Whether it can be driven right now. An `unauthorized` device is a real row
  /// in a listing and not a mistake to hide — but it cannot be tapped.
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
