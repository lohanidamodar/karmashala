import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:riverpod/riverpod.dart';

import 'device_fleet.dart';
import 'device_ports.dart';

/// Install, launch and force-stop from the pane, consulting who holds the
/// device ([deviceHoldersProvider]) — the server's claims, when the server
/// runs on this machine.
final deviceAppActionsProvider = Provider<DeviceAppActions>(
  (ref) => DeviceAppActions(
    fleet: ref.read(deviceFleetProvider),
    clock: ref.watch(deviceClockProvider),
    holderOf: (deviceId) => ref.read(deviceHoldersProvider)[deviceId],
  ),
);
