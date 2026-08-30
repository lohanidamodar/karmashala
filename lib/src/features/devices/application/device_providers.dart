import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import '../data/adb_service.dart';
import '../data/android_sdk_discovery.dart';
import '../data/device_stream.dart';
import '../domain/android_device.dart';
import '../domain/device_input.dart';

/// The environment whose Android SDK the pane uses.
///
/// Windows-native for now. A WSL SDK is a different adb server with a different
/// device list, so switching this is a real user-facing choice rather than a
/// detail — hence a provider rather than a constant.
final deviceEnvironmentProvider = Provider<ExecutionEnvironment>(
  (ref) => localWindowsEnvironment(DateTime.now().toUtc()),
);

/// Locates the Android SDK, or `null` when there is none.
final androidSdkProvider = FutureProvider<AndroidSdk?>((ref) async {
  final environment = ref.watch(deviceEnvironmentProvider);
  final runner = ref
      .watch(commandRunnerFactoryProvider)
      .forEnvironment(environment);
  return AndroidSdkDiscoveryService(
    runner: runner,
    environment: environment,
  ).discover();
});

/// adb access, or `null` when no SDK was found.
final adbServiceProvider = Provider<AdbService?>((ref) {
  final sdk = ref.watch(androidSdkProvider).asData?.value;
  if (sdk == null) return null;
  final environment = ref.watch(deviceEnvironmentProvider);
  final runner = ref
      .watch(commandRunnerFactoryProvider)
      .forEnvironment(environment);
  return AdbService(runner: runner, sdk: sdk);
});

/// Connected devices and emulators. Refresh with `ref.invalidate`.
final devicesProvider = FutureProvider<List<AndroidDevice>>((ref) async {
  final adb = ref.watch(adbServiceProvider);
  if (adb == null) return const [];
  return adb.listDevices();
});

/// AVDs known to the SDK, with any running one marked.
final avdsProvider = FutureProvider<List<Avd>>((ref) async {
  final adb = ref.watch(adbServiceProvider);
  if (adb == null) return const [];
  return adb.listAvds();
});

/// Serial of the device the user has chosen, or `null` for "no explicit
/// choice".
///
/// This is the pane's single source of truth for *which device it is about*.
/// It changes only when someone picks a device — the derived
/// [selectedDeviceProvider] supplies the convenience default, and the live view
/// follows this notifier rather than keeping a second opinion of its own.
final selectedDeviceSerialProvider =
    NotifierProvider<SelectedDeviceSerial, String?>(SelectedDeviceSerial.new);

class SelectedDeviceSerial extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? serial) => state = serial;
}

/// The selected device, defaulting to the only ready one when there is exactly
/// one — which is the common case and saves a click.
final selectedDeviceProvider = Provider<AndroidDevice?>((ref) {
  final devices = ref.watch(devicesProvider).asData?.value ?? const [];
  final ready = devices.where((d) => d.isReady).toList();
  final serial = ref.watch(selectedDeviceSerialProvider);
  if (serial != null) {
    for (final device in devices) {
      if (device.serial == serial) return device;
    }
  }
  return ready.length == 1 ? ready.single : null;
});

/// Screen size of one device, by serial — the coordinate space its taps use.
///
/// Keyed by serial on purpose. It used to be "the screen size of the *selected*
/// device", which is a different device from the one being streamed the moment
/// the two disagree; a tap was then mapped through the wrong resolution and
/// landed in the wrong place on the device you were actually looking at, while
/// appearing to work. Asking for a named device's size makes that impossible to
/// express.
///
/// Cached per serial rather than auto-disposed because `wm size` reports the
/// *physical* screen, which does not change while the device is plugged in —
/// not even on rotation.
final deviceScreenSizeProvider =
    FutureProvider.family<DeviceScreenSize?, String>((ref, serial) async {
      final adb = ref.watch(adbServiceProvider);
      if (adb == null) return null;
      return adb.screenSize(serial);
    });

/// Streaming service for the live view.
final deviceStreamServiceProvider = Provider<DeviceStreamService?>((ref) {
  final adb = ref.watch(adbServiceProvider);
  if (adb == null) return null;
  final environment = ref.watch(deviceEnvironmentProvider);
  return DeviceStreamService(
    adb: adb,
    runner: ref.watch(commandRunnerFactoryProvider).forEnvironment(environment),
    serverBytes: () async {
      final data = await rootBundle.load(kScrcpyServerAsset);
      return data.buffer.asUint8List();
    },
  );
});

/// Why the pane cannot show anything, in the user's terms.
String? deviceUnavailableReason({
  required AndroidSdk? sdk,
  required bool sdkResolved,
  required List<AndroidDevice> devices,
  required EnvironmentKind kind,
}) {
  if (!sdkResolved) return null;
  if (sdk == null) {
    return switch (kind) {
      EnvironmentKind.windowsNative =>
        'No Android SDK found. Set ANDROID_HOME, or install the SDK to '
            r'%LOCALAPPDATA%\Android\Sdk.',
      EnvironmentKind.wsl =>
        r'No Android SDK found in this WSL distribution. Set ANDROID_HOME '
            'or install it to ~/Android/Sdk.',
      EnvironmentKind.ssh =>
        r'No Android SDK found on this remote host. Set ANDROID_HOME there, '
            'or install it to ~/Android/Sdk.',
    };
  }
  if (devices.isEmpty) {
    return 'No devices connected. Plug in a device with USB debugging '
        'enabled, or start an emulator below.';
  }
  if (devices.every((d) => !d.isReady)) {
    final unauthorized = devices.any(
      (d) => d.state == DeviceConnectionState.unauthorized,
    );
    return unauthorized
        ? 'Device connected but not authorised — accept the USB debugging '
              'prompt on the device.'
        : 'Devices are connected but not ready (offline).';
  }
  return null;
}
