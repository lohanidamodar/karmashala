import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'device_ports.dart';
import 'package:agent_cli/process.dart';
import '../../devices.dart';

/// The environment whose Android SDK the pane uses. A provider, not a
/// constant: a WSL SDK is a different adb server with a different list.
final deviceEnvironmentProvider = Provider<ExecutionEnvironment>(
  (ref) => localHostEnvironment(DateTime.now().toUtc()),
);

/// Locates the Android SDK, or `null` when there is none.
final androidSdkProvider = FutureProvider<AndroidSdk?>((ref) async {
  final environment = ref.watch(deviceEnvironmentProvider);
  final runner = ref
      .watch(deviceCommandRunnerFactoryProvider)
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
      .watch(deviceCommandRunnerFactoryProvider)
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

/// Serial of the device the user has chosen, `null` for "no explicit choice" —
/// the pane's one source of truth; [selectedDeviceProvider] adds the default.
final selectedDeviceSerialProvider =
    NotifierProvider<SelectedDeviceSerial, String?>(SelectedDeviceSerial.new);

class SelectedDeviceSerial extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? serial) => state = serial;
}

/// Serial of the device the Android live view is **on**, `null` when off. A
/// provider so the *intent* survives the side panel unmounting the pane.
final androidLiveViewProvider = NotifierProvider<AndroidLiveView, String?>(
  AndroidLiveView.new,
);

class AndroidLiveView extends Notifier<String?> {
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

/// Screen size of one device, by serial — the coordinate space its taps use,
/// cached: `wm size` reports the physical screen, unchanged even by rotation.
final deviceScreenSizeProvider =
    FutureProvider.family<DeviceScreenSize?, String>((ref, serial) async {
      final adb = ref.watch(adbServiceProvider);
      if (adb == null) return null;
      return adb.screenSize(serial);
    });

/// Whether a device starts with no window of its own; headless by default. It
/// takes the AVD's window away and *opens* the simulator's — same promise.
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
    runner: ref.watch(deviceCommandRunnerFactoryProvider).forEnvironment(environment),
    sdk: sdk,
  );
});

/// What one emulator carries from this build, by serial. Auto-disposed and
/// never retried: Restore changes the answer, and a cached one would go stale.
final androidSlimmingStatusProvider = FutureProvider.autoDispose
    .family<AndroidSlimmingStatus?, String>((ref, serial) async {
      final service = ref.watch(androidSlimmingServiceProvider);
      if (service == null) return null;
      return service.status(serial);
    }, retry: (_, _) => null);

/// Whether starting an emulator slims it at all — the master switch.
final androidSlimmingOnStartProvider = Provider<bool>(
  (ref) => ref.watch(deviceSlimmingPreferencesProvider.select((s) => s.androidSlimming)),
);

/// The categories to apply, or empty when slimming is off. Ids that no longer
/// name a category are dropped: a removal must not break a saved preference.
final androidSlimmingCategoriesProvider =
    Provider<Set<AndroidSlimmingCategory>>((ref) {
      if (!ref.watch(androidSlimmingOnStartProvider)) return const {};
      return categoriesFromIds(
        ref.watch(
          deviceSlimmingPreferencesProvider.select((s) => s.androidSlimmingEnabled),
        ),
      );
    });

/// The renderer the emulator is started with.
final androidEmulatorGpuProvider = Provider<AndroidGpuMode>(
  (ref) => AndroidGpuMode.byId(
    ref.watch(deviceSlimmingPreferencesProvider.select((s) => s.androidEmulatorGpu)),
  ),
);

/// The extra `emulator` argv a Start should use. The GPU mode is here even
/// when slimming is off: it is a rendering choice, not an optimisation.
final androidEmulatorArgumentsProvider = Provider<List<String>>(
  (ref) => launchArguments(
    enabled: ref.watch(androidSlimmingCategoriesProvider),
    gpu: ref.watch(androidEmulatorGpuProvider),
  ),
);

/// Runs the two durable layers against a booted emulator, and remembers which
/// serials are mid-flight. Failure is swallowed — a saving is not an outage.
class AndroidSlimming extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  bool isBusy(String serial) => state.contains(serial);

  /// Applies the selected categories to a freshly booted [serial]. The service
  /// waits for `sys.boot_completed` again: a plain `bootAvd` caller may not.
  Future<AndroidSlimmingReport?> applyAfterBoot(String serial) =>
      _run(serial, (service) async {
        final enabled = ref.read(androidSlimmingCategoriesProvider);
        if (enabled.isEmpty) return null;
        return service.apply(serial, enabled: enabled);
      });

  /// Puts everything this build manages back on [serial], ignoring the master
  /// switch: one slimmed before the setting went off still needs restoring.
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
    runner: ref.watch(deviceCommandRunnerFactoryProvider).forEnvironment(environment),
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
    // One sentence: the lists under it are the rest of the answer.
    return 'No device connected. Plug one in, pair one over Wi-Fi from the '
        'toolbar, or start one below.';
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
