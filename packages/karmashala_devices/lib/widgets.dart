/// The surfaces a device is driven through, each usable on its own: the
/// control bars, the touch and keyboard surfaces, the stream's own status,
/// the logcat tail, the recording banner, the simulator's list and pane, and
/// the slimming choices a host can also show outside a dialog.
library;

export 'src/presentation/android_slimming_dialog.dart'
    show AndroidSlimmingSettings;
export 'src/presentation/desktop_key_bridge.dart';
export 'src/presentation/device_app_controls.dart';
export 'src/presentation/device_clipboard_controls.dart';
export 'src/presentation/device_controls.dart';
export 'src/presentation/device_keyboard_surface.dart';
export 'src/presentation/device_logcat_section.dart';
export 'src/presentation/device_recording_banner.dart';
export 'src/presentation/device_section_header.dart';
export 'src/presentation/device_stream_status.dart';
export 'src/presentation/device_touch_surface.dart';
export 'src/presentation/simulator_list.dart';
export 'src/presentation/simulator_live_pane.dart';
export 'src/presentation/simulator_slimming_dialog.dart'
    show SimulatorSlimmingSettings;
