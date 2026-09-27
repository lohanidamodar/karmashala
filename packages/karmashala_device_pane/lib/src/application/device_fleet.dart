import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:riverpod/riverpod.dart';

import 'device_providers.dart';
import 'ios_device_providers.dart';

/// This machine's fleet, for the pane. A **factory**, not a fleet: one cached
/// instance would hand every call the same stale listing. Awaited because a
/// null adb service also means "not yet".
final deviceFleetProvider = Provider<DeviceFleetFactory>((ref) {
  return () async {
    await ref.read(androidSdkProvider.future);
    final transitions = ref.read(simulatorTransitionsProvider.notifier);
    return DeviceFleet(
      adb: ref.read(adbServiceProvider),
      simctl: ref.read(simctlServiceProvider),
      backend: ref.read(simulatorBackendProvider),
      bootSimulator: transitions.boot,
      simulatorIsBusy: transitions.isBusy,
      refreshAndroid: () {
        ref.invalidate(devicesProvider);
        ref.invalidate(avdsProvider);
      },
      refreshSimulators: () => ref.invalidate(iosSimulatorsProvider),
    );
  };
});
