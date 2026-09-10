/// Everything this package knows about a device: the vocabulary (`src/domain`)
/// and the drivers that speak it (`src/data`). Nothing in `domain` starts a
/// process, and nothing here reads a provider — the graph is `providers.dart`
/// and the surfaces are `pane.dart` and `widgets.dart`. A DAO is still the
/// app's; this layer takes values in and hands values back.
library;

export 'src/data/adb_device_driver.dart';
export 'src/data/adb_file_parsing.dart';
export 'src/data/adb_output_parsing.dart';
export 'src/data/adb_service.dart';
export 'src/data/adb_wireless_parsing.dart';
export 'src/data/android_sdk_discovery.dart';
export 'src/data/android_slimming_service.dart';
export 'src/data/avd_system_images.dart';
export 'src/data/device_gesture_sink.dart';
export 'src/data/device_keyboard_sink.dart';
export 'src/data/device_stream.dart';
export 'src/data/host_clipboard.dart';
export 'src/data/loopback_media_server.dart';
export 'src/data/mjpeg_stream.dart';
export 'src/data/recording_sink.dart';
export 'src/data/scrcpy_control.dart';
export 'src/data/scrcpy_device_message.dart';
export 'src/data/scrcpy_protocol.dart';
export 'src/data/simctl_parsing.dart';
export 'src/data/simctl_service.dart';
export 'src/data/simulator_device_driver.dart';
export 'src/data/simulator_slimming_service.dart';
export 'src/data/ts_muxer.dart';
export 'src/data/uiautomator_parsing.dart';
export 'src/data/wda_backend.dart';
export 'src/data/wda_locator.dart';
export 'src/data/wda_ui_parsing.dart';

export 'src/domain/android_device.dart';
export 'src/domain/android_slimming.dart';
export 'src/domain/device_action.dart';
export 'src/domain/device_claim.dart';
export 'src/domain/device_clipboard.dart';
export 'src/domain/device_driver.dart';
export 'src/domain/device_file_clipboard.dart';
export 'src/domain/device_files.dart';
export 'src/domain/device_geometry.dart';
export 'src/domain/device_input.dart';
export 'src/domain/device_keyboard.dart';
export 'src/domain/device_recording.dart';
export 'src/domain/device_target.dart';
export 'src/domain/ios_simulator.dart';
export 'src/domain/logcat_entry.dart';
export 'src/domain/logcat_tail.dart';
export 'src/domain/screen_observation.dart';
export 'src/domain/simulator_backend.dart';
// `featureLossFor` is the same question asked of two platforms and answered
// from two tables. The Android one wins the short name; a caller that wants the
// simulator's imports `src/domain/simulator_slimming.dart`.
export 'src/domain/simulator_slimming.dart' hide featureLossFor;
export 'src/domain/ui_node.dart';
export 'src/domain/ui_summary.dart';
export 'src/domain/wireless_pairing.dart';
