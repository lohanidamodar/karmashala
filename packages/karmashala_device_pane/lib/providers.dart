/// The Riverpod graph over `karmashala_devices`' drivers and cores, for this
/// machine's own devices: what the SDK is, which devices and simulators there
/// are, which one is selected, what is being recorded, logcat, the live views,
/// wireless pairing — and the cores themselves, re-exported.
library;

export 'package:karmashala_devices/karmashala_devices.dart';

export 'src/application/device_app_actions.dart';
export 'src/application/device_clipboard_bridge.dart';
export 'src/application/device_fleet.dart';
export 'src/application/device_logcat_session.dart';
export 'src/application/device_logcat_view.dart';
export 'src/application/device_providers.dart';
export 'src/application/device_recording_controller.dart';
export 'src/application/ios_device_providers.dart';
export 'src/application/simulator_frames.dart';
export 'src/application/simulator_live_view.dart';
export 'src/application/wireless_pairing_controller.dart';
export 'src/data/host_clipboard.dart';
