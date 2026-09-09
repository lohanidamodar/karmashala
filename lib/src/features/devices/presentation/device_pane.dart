import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/media/video_support_provider.dart';
import '../application/device_clipboard_bridge.dart';
import '../application/device_providers.dart';
import '../application/device_recording_controller.dart';
import '../application/stream_restart_policy.dart';
import '../data/device_gesture_sink.dart';
import '../data/device_keyboard_sink.dart';
import '../data/adb_service.dart';
import '../data/device_stream.dart';
import '../application/ios_device_providers.dart';
import '../domain/android_device.dart';
import '../domain/ios_simulator.dart';
import '../domain/device_input.dart';
import '../domain/device_recording.dart';
import '../domain/device_target.dart';
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
    with WidgetsBindingObserver, _DeviceLiveStream {
  /// Emulators with a shutdown in flight, by serial — one per row, because the
  /// list can offer to stop more than one.
  final Set<String> _stopping = <String>{};

  /// AVDs with a boot in flight, by AVD name. Headless there is nothing to
  /// watch, so the row has to say it is starting or the click looks ignored.
  final Set<String> _booting = <String>{};

  /// Boots an AVD and opens the live view on it.
  ///
  /// One flow, not two steps: with `-no-window` the live view is the only way
  /// to see the thing that was just started, so starting it and showing it are
  /// the same intent.
  Future<void> _bootAvd(String name) async {
    final adb = ref.read(adbServiceProvider);
    if (adb == null || _booting.contains(name)) return;
    setState(() => _booting.add(name));
    String? serial;
    String? failure;
    try {
      serial = await adb.bootAvdAndWait(
        name,
        headless: ref.read(headlessDeviceProvider),
        extraArguments: ref.read(androidEmulatorArgumentsProvider),
      );
      // After the wait, never before: `settings put` and `pm disable-user` both
      // need a running package manager. Failure inside is logged and swallowed
      // — an emulator that started is worth more than one that was slimmed.
      await ref.read(androidSlimmingProvider.notifier).applyAfterBoot(serial);
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() => _booting.remove(name));
    ref.invalidate(devicesProvider);
    ref.invalidate(avdsProvider);
    if (failure != null || serial == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(failure ?? '$name did not start.')),
      );
      return;
    }
    // Wait for the refreshed list rather than reading the stale one: the device
    // that was just booted is precisely the one not in it yet.
    final devices = await ref.read(devicesProvider.future);
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    if (!mounted || device == null || !device.isReady) return;
    await _startStream(device);
  }

  Future<void> _stopEmulator({
    required String serial,
    required String label,
  }) async {
    final adb = ref.read(adbServiceProvider);
    if (adb == null || _stopping.contains(serial)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop $label?'),
        content: const Text(
          'The emulator will shut down. Anything it has not written to a '
          'snapshot is lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop emulator'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _stopping.add(serial));
    // Take the stream down first: killing the emulator underneath a live view
    // produces exactly the frozen picture Loop 36 set out to fix, and it would
    // look like a new fault rather than the shutdown the user asked for.
    if (_liveSerial == serial) await _stopStream();
    String? failure;
    try {
      final stopped = await adb.stopEmulator(serial);
      if (!stopped) {
        failure = '$label did not exit.';
      }
    } catch (error) {
      failure = '$error';
    }
    if (!mounted) return;
    setState(() => _stopping.remove(serial));
    if (failure == null && ref.read(selectedDeviceSerialProvider) == serial) {
      // Leaving the dead serial selected would pin the picker to a device that
      // no longer exists.
      ref.read(selectedDeviceSerialProvider.notifier).select(null);
    }
    ref.invalidate(devicesProvider);
    ref.invalidate(avdsProvider);
    ref.invalidate(deviceScreenSizeProvider(serial));
    if (failure != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(failure)));
    }
  }

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

    // Stop streaming a device that went away — once the list has actually
    // said so. A refresh in flight reads as the same empty list as a machine
    // with nothing plugged in, and tearing the live view down for one is what
    // a resume would run into first.
    if (_liveSerial != null &&
        deviceList.hasValue &&
        !devices.any((d) => d.serial == _liveSerial && d.isReady)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_stopAndRebuild());
      });
    }

    // The same rule for a simulator, which did not have it: shutting one down
    // left its picture on screen showing the last frame that ever arrived. A
    // still image of a device that no longer exists is the worst kind of
    // wrong — it is indistinguishable from a live device that has stopped
    // moving, and every control on it goes on offering to drive something that
    // is gone.
    final liveSimulatorUdid = switch (ref.watch(simulatorLiveViewProvider)) {
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewStarting(:final udid) => udid,
      _ => null,
    };
    // Only once the list has actually come back. `bootedSimulatorsProvider`
    // reads the same empty list while the load is in flight as it does when
    // every simulator really has gone, so testing it directly would tear the
    // picture down on every refresh — the same "null means both *loading* and
    // *absent*" mistake that made the device surface report a missing Android
    // SDK on a machine that had one.
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

    // The device the pane is about. While the live view is running it is the
    // device that view is for; the two are the same by construction, and
    // reading it from one place is what keeps them that way.
    final live = _liveSerial == null
        ? null
        : devices.where((d) => d.serial == _liveSerial).firstOrNull;
    final paneDevice = live ?? selected;

    // Whether the simulator's picture is what this pane is showing. Named once
    // and used twice, because the body below and the control row underneath it
    // have to agree: they did not, and an Android hardware-key row sat beneath
    // an iPhone's picture, pointed at a device that was not on screen.
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
        // Above the picture and outside both platform branches: a recording is
        // the one thing on this pane that outlives the surface it was started
        // from, so it cannot live inside the row that is replaced when the
        // simulator's picture wins.
        const DeviceRecordingBanner(),
        const Divider(height: 1),
        Expanded(
          // The simulator's picture wins while it is up. It is the only thing
          // on screen the user asked for by name, and the Android branches
          // below are all about a device they did not pick.
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
                  // picture does not blink out and back. It is covered and
                  // labelled — see [_LiveView.reconnecting].
                  video: _video ?? _heldVideo,
                  device: live,
                  // A remount shows the spinner, never the last frame: the
                  // held picture is a `Player` that went with the old element,
                  // and there is nothing to hold it in between.
                  starting: _starting || _resuming,
                  reconnecting: _holdingPicture,
                  sink: _sink,
                  keyboard: _keyboardSink,
                  health: _health,
                  exhausted: _restarts.isExhausted && _reconnectTimer == null,
                  // Still being found out, rather than found to be empty. The
                  // SDK is resolved once, and the device list is only
                  // "unknown" until its first answer — a later refresh has the
                  // previous answer to stand on, and re-announcing the search
                  // over a list the user can already see would be a flicker,
                  // not information.
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
        // controls, and this row would sit under an iPhone offering Back,
        // Recents and a screenshot of an Android device the user is not
        // looking at.
        if (!simulatorShowing && paneDevice != null) ...[
          const Divider(height: 1),
          // Deliberately [live], not [paneDevice]: a hardware key is *input*,
          // and input follows the running session rather than the selection.
          // Stopping the live view used to leave these driving whichever device
          // happened to be selected — the user believed they had disconnected
          // and had not. The row stays on screen, disabled, because a control
          // that vanishes reads as a fault while an inert one says why.
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
