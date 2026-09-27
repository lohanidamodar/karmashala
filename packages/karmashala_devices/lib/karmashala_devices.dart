/// Driving an Android device or an iOS simulator from a machine: pure Dart
/// since slice 4a, so the server drives its machine's devices with the same
/// code a pane drives its own. `devices.dart` is the vocabulary and every
/// driver; this adds the cores above them — the fleet, the claims, the app
/// actions, the screen memory, recording, a logcat session, wireless pairing,
/// where a pulled file is put and whether a dead mirror is dialled again.
///
/// The Riverpod graph, the pane and its widgets are `karmashala_device_pane`.
library;

export 'devices.dart';
export 'src/application/device_app_actions.dart';
export 'src/application/device_claims.dart';
export 'src/application/device_file_actions.dart';
export 'src/application/device_file_staging.dart';
export 'src/application/device_fleet.dart';
export 'src/application/device_logcat_session.dart';
export 'src/application/device_recorder.dart';
export 'src/application/device_screen_memory.dart';
export 'src/application/stream_restart_policy.dart';
export 'src/application/wireless_pairing_flow.dart';
