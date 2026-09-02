import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import '../../settings/application/settings_controller.dart';
import '../data/adb_service.dart';
import '../data/android_sdk_discovery.dart';
import '../data/android_slimming_service.dart';
import '../data/device_stream.dart';
import '../domain/android_device.dart';
import '../domain/android_slimming.dart';
import '../domain/device_input.dart';

/// The environment whose Android SDK the pane uses.
///
/// Windows-native for now. A WSL SDK is a different adb server with a different
/// device list, so switching this is a real user-facing choice rather than a
/// detail — hence a provider rather than a constant.
final deviceEnvironmentProvider = Provider<ExecutionEnvironment>(
  (ref) => localHostEnvironment(DateTime.now().toUtc()),
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

/// Whether a device is started without a window of its own.
///
/// Defaults to headless. This pane already shows the device, drives it and
/// reads its accessibility tree, so a second floating window is in the way
/// rather than useful — which is exactly how Android Studio's embedded
/// emulator behaves. It is a toggle rather than a constant because the
/// emulator's extended controls (rotation, location, simulated calls) only
/// exist in that window, and some tasks need them.
///
/// It governs both platforms, but from opposite directions, and the wording
/// has to survive that. An AVD's window is the *default* and `-no-window`
/// takes it away. An iOS simulator booted through `simctl` has no window at
/// all — Simulator.app is a separate application that attaches to a booted
/// device — so there the switch does not suppress a window, it opens one.
/// Same promise to the user either way: on, you get the device here and
/// nowhere else; off, it also has its own window.
final headlessDeviceProvider = NotifierProvider<HeadlessDevice, bool>(
  HeadlessDevice.new,
);

class HeadlessDevice extends Notifier<bool> {
  @override
  bool build() => true;

  void update(bool headless) => state = headless;
}

/// Applies the durable slimming layers, or `null` when no SDK was found.
final androidSlimmingServiceProvider = Provider<AndroidSlimmingService?>((ref) {
  final sdk = ref.watch(androidSdkProvider).asData?.value;
  if (sdk == null) return null;
  final environment = ref.watch(deviceEnvironmentProvider);
  return AndroidSlimmingService(
    runner: ref.watch(commandRunnerFactoryProvider).forEnvironment(environment),
    sdk: sdk,
  );
});

/// What one emulator currently carries from this build, by serial.
///
/// Auto-disposed rather than cached: it is read while the slimming dialog is
/// open, and the answer changes the moment Restore runs. A cached one would go
/// on offering Restore for something already put back.
///
/// Two `adb` calls against a device that may have gone away, so it retries
/// nothing — a failure stays a failure until the dialog is opened again, which
/// is cheaper than a background loop polling a device nobody is looking at.
final androidSlimmingStatusProvider = FutureProvider.autoDispose
    .family<AndroidSlimmingStatus?, String>((ref, serial) async {
      final service = ref.watch(androidSlimmingServiceProvider);
      if (service == null) return null;
      return service.status(serial);
    }, retry: (_, _) => null);

/// Whether starting an emulator slims it at all — the master switch.
final androidSlimmingOnStartProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider.select((s) => s.androidSlimming)),
);

/// The categories to apply, or empty when slimming is off.
///
/// Ids that no longer name a category are dropped rather than erroring: a
/// category removed in a later release must not make a saved preference
/// unreadable.
final androidSlimmingCategoriesProvider =
    Provider<Set<AndroidSlimmingCategory>>((ref) {
      if (!ref.watch(androidSlimmingOnStartProvider)) return const {};
      return categoriesFromIds(
        ref.watch(
          settingsControllerProvider.select((s) => s.androidSlimmingEnabled),
        ),
      );
    });

/// The renderer the emulator is started with.
final androidEmulatorGpuProvider = Provider<AndroidGpuMode>(
  (ref) => AndroidGpuMode.byId(
    ref.watch(settingsControllerProvider.select((s) => s.androidEmulatorGpu)),
  ),
);

/// The extra `emulator` argv a Start should use.
///
/// The GPU mode is here even when slimming is off: it is a rendering choice
/// about this pane's preview, not an optimisation, and switching slimming off
/// must not silently swap the renderer back.
final androidEmulatorArgumentsProvider = Provider<List<String>>(
  (ref) => launchArguments(
    enabled: ref.watch(androidSlimmingCategoriesProvider),
    gpu: ref.watch(androidEmulatorGpuProvider),
  ),
);

/// Runs the two durable layers against a booted emulator, and remembers which
/// serials are mid-flight so a button can say so.
///
/// Both methods swallow failure. Slimming is an optimisation, and refusing to
/// hand over an emulator because its animations could not be zeroed would turn
/// a saving into an outage — the rule `ios_device_providers.dart` states for
/// the iOS side, and the reason it is repeated here rather than inherited.
class AndroidSlimming extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool isBusy(String serial) => state.contains(serial);

  /// Applies the selected categories to a freshly booted [serial].
  ///
  /// Called after `bootAvdAndWait`, which already waited for
  /// `sys.boot_completed` — the service waits again anyway, because a caller
  /// that used plain `bootAvd` would otherwise be writing settings into a
  /// half-booted system.
  Future<AndroidSlimmingReport?> applyAfterBoot(String serial) =>
      _run(serial, (service) async {
        final enabled = ref.read(androidSlimmingCategoriesProvider);
        if (enabled.isEmpty) return null;
        return service.apply(serial, enabled: enabled);
      });

  /// Puts everything this build manages back on [serial].
  ///
  /// Deliberately ignores the master switch: an emulator that was slimmed while
  /// the setting was on still needs restoring after it is turned off, and that
  /// is precisely the case a user cannot otherwise get out of.
  Future<AndroidSlimmingReport?> restore(String serial) =>
      _run(serial, (service) => service.restore(serial));

  Future<AndroidSlimmingReport?> _run(
    String serial,
    Future<AndroidSlimmingReport?> Function(AndroidSlimmingService service)
    action,
  ) async {
    final service = ref.read(androidSlimmingServiceProvider);
    if (service == null || isBusy(serial)) return null;
    state = {...state, serial};
    try {
      final report = await action(service);
      if (report != null && !report.ok) {
        _log.warning(
          'Slimming $serial left ${report.failed.length} step(s) undone '
          '${report.failed}',
        );
      }
      return report;
    } on Object catch (error) {
      _log.warning('Slimming $serial did not run reason=$error');
      return null;
    } finally {
      state = {...state}..remove(serial);
    }
  }

  static final _log = AppLogger.named('android-slimming');
}

final androidSlimmingProvider =
    NotifierProvider<AndroidSlimming, Set<String>>(AndroidSlimming.new);

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
      EnvironmentKind.localPosix =>
        'No Android SDK found. Set ANDROID_HOME, or install the SDK to '
            '~/Library/Android/sdk on macOS or ~/Android/Sdk on Linux.',
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
