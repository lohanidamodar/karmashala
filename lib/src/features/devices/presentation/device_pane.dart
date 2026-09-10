import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_core/logging.dart';
import '../../../core/media/video_support_provider.dart';
import '../../../core/util/file_picking.dart' show PickerQuiet;
import '../application/device_clipboard_bridge.dart';
import '../application/device_providers.dart';
import '../application/device_recording_controller.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import '../application/ios_device_providers.dart';
import 'android_slimming_dialog.dart';
import 'device_clipboard_controls.dart';
import 'device_files_dialog.dart';
import 'device_section_header.dart';
import 'device_controls.dart';
import 'device_app_controls.dart';
import 'device_keyboard_surface.dart';
import 'device_logcat_section.dart';
import 'device_recording_banner.dart';
import 'device_stream_status.dart';
import '../application/simulator_live_view.dart';
import 'simulator_live_pane.dart';
import 'simulator_list.dart';
import 'device_touch_surface.dart';
import 'wireless_pairing_dialog.dart';

part 'device_pane_device_list.dart';
part 'device_pane_emulator_power.dart';
part 'device_pane_hardware_controls.dart';
part 'device_pane_live_view.dart';
part 'device_pane_stream.dart';
part 'device_pane_toolbar.dart';

/// The device pane: pick a device or emulator, watch it live, and drive it.
class DevicePane extends ConsumerStatefulWidget {
  const DevicePane({super.key});

  @override
  ConsumerState<DevicePane> createState() => _DevicePaneState();
}

class _DevicePaneState extends ConsumerState<DevicePane>
    with WidgetsBindingObserver, _DeviceLiveStream, _DeviceEmulatorPower {
  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      selectedDeviceSerialProvider,
      (_, serial) => _onSelectionChanged(serial),
    );
    final sdk = ref.watch(androidSdkProvider);
    final deviceList = ref.watch(devicesProvider);
    final devices = deviceList.asData?.value ?? const <AndroidDevice>[];
    final selected = ref.watch(selectedDeviceProvider);
    final reason = deviceUnavailableReason(
      sdk: sdk.asData?.value,
      sdkResolved: sdk.asData != null || sdk.hasError,
      devices: devices,
      kind: ref.watch(deviceEnvironmentProvider).kind,
    );

    // Stop streaming a device that went away — once the list has said so: a
    // refresh in flight reads as the same empty list as nothing plugged in.
    if (_liveSerial != null &&
        deviceList.hasValue &&
        !devices.any((d) => d.serial == _liveSerial && d.isReady)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_stopAndRebuild());
      });
    }

    // The same rule for a simulator: a still image of a device that no longer
    // exists cannot be told from a live one that has stopped moving.
    final liveSimulatorUdid = switch (ref.watch(simulatorLiveViewProvider)) {
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewStarting(:final udid) => udid,
      _ => null,
    };
    // Only once the list has come back: a load in flight reads the same empty
    // list as every simulator having gone, and would tear the picture down.
    final simulatorList = ref.watch(iosSimulatorsProvider);
    final knownBooted = simulatorList.asData?.value.where(
      (s) => s.state.isReady || s.state == SimulatorState.booting,
    );
    if (liveSimulatorUdid != null &&
        knownBooted != null &&
        !knownBooted.any((s) => s.udid == liveSimulatorUdid)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(ref.read(simulatorLiveViewProvider.notifier).stop());
        }
      });
    }

    // The device the pane is about: while the live view runs it is that
    // view's device, and reading it from one place keeps them the same.
    final live = _liveSerial == null
        ? null
        : devices.where((d) => d.serial == _liveSerial).firstOrNull;
    final paneDevice = live ?? selected;

    // Whether the simulator's picture is what this pane shows. Named once and
    // used twice: an Android key row once sat beneath an iPhone's picture.
    final simulatorShowing =
        ref.watch(simulatorLiveViewProvider) is! SimulatorLiveViewIdle;

    return Column(
      children: [
        _DeviceToolbar(
          devices: devices,
          selected: selected,
          streaming: _liveSerial != null,
          starting: _starting || _resuming,
          stoppingEmulator:
              selected != null && _stopping.contains(selected.serial),
          onStart: selected == null ? null : () => _startStream(selected),
          onRestart: _liveSerial == null ? null : _restartStream,
          onStopEmulator: selected != null && selected.isEmulator
              ? () => _stopEmulator(
                  serial: selected.serial,
                  label: selected.displayName,
                )
              : null,
          onStop: _liveSerial == null ? null : _stopAndRebuild,
        ),
        // Above the picture and outside both platform branches: a recording
        // outlives the surface it was started from.
        const DeviceRecordingBanner(),
        const Divider(height: 1),
        Expanded(
          // The simulator's picture wins while it is up: it is the only thing
          // on screen the user asked for by name.
          child: simulatorShowing
              ? const SimulatorLivePane()
              : reason != null
              ? _DeviceEmptyState(
                  message: reason,
                  stopping: _stopping,
                  booting: _booting,
                  onPreview: _startStream,
                  onStopEmulator: _stopEmulator,
                  onBootAvd: _bootAvd,
                )
              : _streamError != null
              ? _DeviceEmptyState(
                  message:
                      'Live view unavailable: $_streamError\n\n'
                      'Screenshots, input and logcat still work.',
                  stopping: _stopping,
                  booting: _booting,
                  onPreview: _startStream,
                  onStopEmulator: _stopEmulator,
                  onBootAvd: _bootAvd,
                )
              : _LiveView(
                  // The held frame while a restart is in flight, so the
                  // picture does not blink out and back — covered, and said.
                  video: _video ?? _heldVideo,
                  device: live,
                  // A remount shows the spinner, never the last frame: the
                  // held picture went with the old element.
                  starting: _starting || _resuming,
                  reconnecting: _holdingPicture,
                  sink: _sink,
                  keyboard: _keyboardSink,
                  health: _health,
                  exhausted: _restarts.isExhausted && _reconnectTimer == null,
                  // Still being found out, rather than found to be empty:
                  // only the first answer is unknown, and re-asking flickers.
                  probing:
                      !(sdk.asData != null || sdk.hasError) ||
                      !deviceList.hasValue,
                  onRestart: _restartStream,
                  stopping: _stopping,
                  booting: _booting,
                  onPreview: _startStream,
                  onStopEmulator: _stopEmulator,
                  onBootAvd: _bootAvd,
                ),
        ),
        // Not while a simulator's picture is up: that pane carries its own
        // controls, and this row would offer Back under an iPhone.
        if (!simulatorShowing && paneDevice != null) ...[
          const Divider(height: 1),
          // Deliberately [live], not [paneDevice]: input follows the running
          // session, or Stop leaves these driving whatever is selected.
          _AndroidControls(
            device: live,
            clipboard: _clipboard,
            recordable: _session != null,
          ),
          // Install / launch / force-stop, through the same claim the tools
          // take — so a device an agent is driving refuses these by name.
          DeviceAppControls(device: paneDevice),
          // [paneDevice], not [live]: reading a log is not driving, so it
          // follows the selection and works with no live view up at all.
          DeviceLogcatSection(device: paneDevice),
        ],
      ],
    );
  }
}
