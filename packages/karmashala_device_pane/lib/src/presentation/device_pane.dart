import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_core/logging.dart';
import '../application/device_ports.dart';
import 'package:karmashala_ui/picking.dart' show PickerQuiet;
import '../application/device_clipboard_bridge.dart';
import '../application/device_providers.dart';
import '../application/device_recording_controller.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import '../application/ios_device_providers.dart';
import 'android_slimming_dialog.dart';
import 'device_clipboard_controls.dart';
import 'device_files_dialog.dart';
import 'device_hold.dart';
import 'device_list_row.dart';
import 'device_section_header.dart';
import 'device_start_options.dart';
import 'device_controls.dart';
import 'device_app_controls.dart';
import 'device_apps_dialog.dart';
import 'device_keyboard_surface.dart';
import 'device_logcat_section.dart';
import 'device_recording_banner.dart';
import 'device_recording_indicator.dart';
import 'device_stream_status.dart';
import '../application/simulator_live_view.dart';
import 'simulator_live_pane.dart';
import 'simulator_list.dart';
import 'device_toolbar_model.dart';
import 'device_touch_surface.dart';
import 'wireless_pairing_dialog.dart';

part 'device_pane_device_list.dart';
part 'device_pane_emulator_power.dart';
part 'device_pane_hardware_controls.dart';
part 'device_pane_live_view.dart';
part 'device_pane_stream.dart';
part 'device_pane_toolbar.dart';

/// The device pane: pick a device or emulator, watch it live, and drive it.
///
/// Two shapes. **The list** (the default): every device and emulator, each
/// row acting on its own device — live view, files, install. Where the host
/// opens tabs ([devicePreviewOpenerProvider]) that is all it is, and a live
/// view opens as **a preview** ([DevicePane.preview]): one device's picture,
/// its controls, install/launch and its log, in a tab of its own — so one
/// phone can be watched while another's files are read (owner, 2026-09-30).
class DevicePane extends ConsumerStatefulWidget {
  const DevicePane({super.key}) : previewSerial = null, focused = false;

  /// The live preview of the device with [serial].
  const DevicePane.preview({
    required String serial,
    this.focused = false,
    super.key,
  }) : previewSerial = serial;

  /// The one device this is a preview of, or null for the list.
  final String? previewSerial;

  /// Whether the workbench's focus is on this preview: typing then goes to
  /// the device.
  final bool focused;

  @override
  ConsumerState<DevicePane> createState() => _DevicePaneState();
}

class _DevicePaneState extends ConsumerState<DevicePane>
    with WidgetsBindingObserver, _DeviceLiveStream, _DeviceEmulatorPower {
  @override
  void initState() {
    super.initState();
    // A pane mounted over a live view whose device vanished while it was away
    // hears no change to react to, so it looks once.
    WidgetsBinding.instance.addPostFrameCallback((_) => _dropVanishedDevices());
  }

  /// Takes down a picture whose device has gone. Run when the lists or the
  /// live views change — never from `build`, which once asked again after
  /// every frame while the first stop was still in flight.
  void _dropVanishedDevices() {
    if (!mounted) return;
    // Stop streaming a device that went away — once the list has said so: a
    // refresh in flight reads as the same empty list as nothing plugged in.
    final deviceList = ref.read(devicesProvider);
    final liveSerial = _liveSerial;
    if (liveSerial != null &&
        deviceList.hasValue &&
        !deviceList.requireValue.any(
          (d) => d.serial == liveSerial && d.isReady,
        )) {
      unawaited(_stopAndRebuild());
    }

    // The same rule for a simulator: a still image of a device that no longer
    // exists cannot be told from a live one that has stopped moving.
    final liveSimulatorUdid = switch (ref.read(simulatorLiveViewProvider)) {
      SimulatorLiveViewRunning(:final view) => view.udid,
      SimulatorLiveViewStarting(:final udid) => udid,
      _ => null,
    };
    // Only once the list has come back: a load in flight reads the same empty
    // list as every simulator having gone, and would tear the picture down.
    final knownBooted = ref
        .read(iosSimulatorsProvider)
        .asData
        ?.value
        .where((s) => s.state.isReady || s.state == SimulatorState.booting);
    if (liveSimulatorUdid == null) _stoppingSimulator = null;
    if (liveSimulatorUdid != null &&
        liveSimulatorUdid != _stoppingSimulator &&
        knownBooted != null &&
        !knownBooted.any((s) => s.udid == liveSimulatorUdid)) {
      _stoppingSimulator = liveSimulatorUdid;
      unawaited(ref.read(simulatorLiveViewProvider.notifier).stop());
    }
  }

  /// The vanished simulator a stop has already been asked for, so a second
  /// notification while that stop runs does not ask again.
  String? _stoppingSimulator;

  /// [_dropVanishedDevices] from a provider notification, one microtask on:
  /// the stop writes providers of its own, which a listener must not do.
  void _onDevicesChanged(Object? _, Object? _) =>
      scheduleMicrotask(_dropVanishedDevices);

  _DeviceListActions get _listActions => _DeviceListActions(
    stopping: _stopping,
    booting: _booting,
    onPreview: _preview,
    onStopEmulator: _stopEmulator,
    onBootAvd: _bootAvd,
  );

  /// The list alone: the picture is a tab's.
  Widget _buildList(BuildContext context) {
    ref.listen(iosSimulatorsProvider, _onDevicesChanged);
    ref.listen(simulatorLiveViewProvider, _onDevicesChanged);
    final sdk = ref.watch(androidSdkProvider);
    final deviceList = ref.watch(devicesProvider);
    final reason = deviceUnavailableReason(
      sdk: sdk.asData?.value,
      sdkResolved: sdk.asData != null || sdk.hasError,
      devices: deviceList.asData?.value ?? const <AndroidDevice>[],
      kind: ref.watch(deviceEnvironmentProvider).kind,
    );
    final probing =
        !(sdk.asData != null || sdk.hasError) || !deviceList.hasValue;
    // A simulator's picture is still this pane's: it has no tab yet.
    final simulatorShowing =
        ref.watch(simulatorLiveViewProvider) is! SimulatorLiveViewIdle;
    return Column(
      children: [
        const _DeviceListToolbar(),
        const DeviceRecordingBanner(),
        const Divider(height: 1),
        Expanded(
          child: simulatorShowing
              ? const SimulatorLivePane()
              : _DeviceEmptyState(
                  message:
                      reason ??
                      (probing
                          ? 'Looking for devices…'
                          : 'Open a live view, browse files or install a '
                                'build from a device\'s row.'),
                  actions: _listActions,
                ),
        ),
      ],
    );
  }

  /// One device's preview: its picture, its controls, its apps and its log.
  Widget _buildPreview(BuildContext context, String serial) {
    ref.listen(devicesProvider, _onDevicesChanged);
    // A microtask on: starting and stopping write providers of their own.
    ref.listen<Set<String>>(
      androidLivePreviewsProvider,
      (_, _) => scheduleMicrotask(() => _followPreviewIntent(serial)),
    );
    final sdk = ref.watch(androidSdkProvider);
    final deviceList = ref.watch(devicesProvider);
    final devices = deviceList.asData?.value ?? const <AndroidDevice>[];
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    final ready = device != null && device.isReady;
    final on = ref.watch(androidLivePreviewsProvider).contains(serial);
    final busy = _starting || _resuming;
    final probing =
        !(sdk.asData != null || sdk.hasError) || !deviceList.hasValue;
    final canStream = ref.watch(deviceStreamServiceProvider) != null;
    // Input follows the running session, as in the pane.
    final live = on ? device : null;
    final name = device?.displayName ?? serial;
    final start = ready && canStream ? () => _startStream(device) : null;

    final Widget picture;
    if (!ready) {
      picture = PanePlaceholder(
        icon: AppIcons.deviceMobile,
        message: probing
            ? 'Looking for $name…'
            : '$name is not connected. Plug it in, or start it from Devices.',
      );
    } else if (!canStream) {
      picture = PanePlaceholder(
        icon: AppIcons.deviceMobile,
        message:
            'The live view is not available on this machine — screenshots, '
            'input and logcat still work.',
      );
    } else if (_streamError != null) {
      picture = PanePlaceholder(
        icon: AppIcons.warning,
        iconColor: Theme.of(context).colorScheme.error,
        message:
            'Live view unavailable: $_streamError — screenshots, input and '
            'logcat still work.',
        action: TextButton.icon(
          onPressed: start,
          icon: const Icon(AppIcons.eye),
          label: const Text('Try again'),
        ),
      );
    } else if (!on && !busy) {
      // A tab brought back by a restart, or one switched off: it does not
      // reach for the phone until asked.
      picture = PanePlaceholder(
        icon: AppIcons.eyeSlash,
        message: 'The live view of $name is off.',
        action: FilledButton.icon(
          onPressed: start,
          icon: const Icon(AppIcons.eye),
          label: const Text('Start live view'),
        ),
      );
    } else {
      final video = _video ?? _heldVideo;
      picture = _LiveView(
        video: video,
        device: device,
        // No picture yet is "starting" here: there is no list to fall back to.
        starting: busy || video == null,
        reconnecting: _holdingPicture,
        sink: _sink,
        keyboard: _keyboardSink,
        health: _health,
        exhausted: _restarts.isExhausted && _reconnectTimer == null,
        probing: probing,
        onRestart: _restartStream,
        listActions: _listActions,
        focusKeyboard: widget.focused,
      );
    }

    return Column(
      children: [
        _PreviewToolbar(
          name: name,
          serial: serial,
          on: on,
          busy: busy,
          onStart: start,
          onStop: _stopAndRebuild,
          onRestart: on ? _restartStream : null,
          onFiles: ready
              ? () => DeviceFilesDialog.show(context, device)
              : null,
        ),
        const DeviceRecordingBanner(),
        const Divider(height: 1),
        Expanded(
          child: _DevicePaneLayout(
            picture: picture,
            controls: device == null
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
                      _AndroidControls(
                        device: live,
                        clipboard: _clipboard,
                        recordable: _session != null,
                      ),
                      DeviceAppControls(device: device),
                    ],
                  ),
            // Reading a log is not driving: it works with the live view off.
            logcat: device == null
                ? null
                : (logHeight) => DeviceLogcatSection(
                    device: device,
                    logHeight: logHeight,
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.previewSerial;
    if (preview != null) return _buildPreview(context, preview);
    if (ref.watch(devicePreviewOpenerProvider) != null) {
      return _buildList(context);
    }
    ref.listen<String?>(
      selectedDeviceSerialProvider,
      (_, serial) => _onSelectionChanged(serial),
    );
    ref.listen(devicesProvider, _onDevicesChanged);
    ref.listen(iosSimulatorsProvider, _onDevicesChanged);
    ref.listen(simulatorLiveViewProvider, _onDevicesChanged);
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

    // One bundle for every place the device list can be drawn from.
    final listActions = _DeviceListActions(
      stopping: _stopping,
      booting: _booting,
      onPreview: _startStream,
      onStopEmulator: _stopEmulator,
      onBootAvd: _bootAvd,
    );

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
          child: _DevicePaneLayout(
            // The simulator's picture wins while it is up: it is the only thing
            // on screen the user asked for by name.
            picture: simulatorShowing
                ? const SimulatorLivePane()
                : reason != null
                ? _DeviceEmptyState(message: reason, actions: listActions)
                : _streamError != null
                ? _DeviceEmptyState(
                    // One paragraph: it is a line above the list, not a page.
                    message:
                        'Live view unavailable: $_streamError — screenshots, '
                        'input and logcat still work.',
                    failed: true,
                    actions: listActions,
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
                    listActions: listActions,
                  ),
            // Not while a simulator's picture is up: that pane carries its own
            // controls, and this row would offer Back under an iPhone.
            controls: simulatorShowing || paneDevice == null
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
                      // Deliberately [live], not [paneDevice]: input follows the
                      // running session, or Stop leaves these driving whatever
                      // is selected.
                      _AndroidControls(
                        device: live,
                        clipboard: _clipboard,
                        recordable: _session != null,
                      ),
                      // Install / launch / force-stop, through the same claim
                      // the tools take — so a device an agent is driving refuses
                      // these by name.
                      DeviceAppControls(device: paneDevice),
                    ],
                  ),
            // [paneDevice], not [live]: reading a log is not driving, so it
            // follows the selection and works with no live view up at all.
            logcat: simulatorShowing || paneDevice == null
                ? null
                : (logHeight) => DeviceLogcatSection(
                    device: paneDevice,
                    logHeight: logHeight,
                  ),
          ),
        ),
      ],
    );
  }
}

/// The pane below its toolbar: the picture, the controls under it, and the
/// log under those. Fixed-height rows under an `Expanded` picture once left
/// the picture 64px with the log open in a 240px side panel, so the picture is
/// guaranteed a share first; the log is sized to the pane, and the controls
/// scroll in whatever is left.
class _DevicePaneLayout extends StatelessWidget {
  const _DevicePaneLayout({
    required this.picture,
    required this.controls,
    required this.logcat,
  });

  final Widget picture;
  final Widget? controls;

  /// Builds the log section for a log body of the given height.
  final Widget Function(double logHeight)? logcat;

  /// The least the picture is left, as a height and as a share of the pane:
  /// whichever is larger, unless the pane itself is smaller.
  static const pictureFloor = 160.0;
  static const pictureShare = 0.45;

  /// The open log's height: [logMax] where there is room, [logShare] of the
  /// pane where there is not.
  static const logMax = 220.0;
  static const logShare = 0.35;

  /// Kept for the log's strip whatever the picture wants, at 1x text: the strip
  /// is how the log is closed again.
  static const stripFloor = 48.0;

  @override
  Widget build(BuildContext context) {
    final controls = this.controls;
    final logcat = this.logcat;
    if (controls == null && logcat == null) return picture;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final wanted = math.max(pictureFloor, height * pictureShare);
        final pictureMin = math.max(
          0.0,
          math.min(wanted, height - scaler.scale(stripFloor)),
        );
        return CustomMultiChildLayout(
          delegate: _DevicePaneLayoutDelegate(pictureMin: pictureMin),
          children: [
            LayoutId(id: _DevicePaneSlot.picture, child: picture),
            if (controls != null)
              LayoutId(
                id: _DevicePaneSlot.controls,
                child: SingleChildScrollView(primary: false, child: controls),
              ),
            if (logcat != null)
              LayoutId(
                id: _DevicePaneSlot.logcat,
                child: ClipRect(
                  child: logcat(math.min(logMax, height * logShare)),
                ),
              ),
          ],
        );
      },
    );
  }
}

enum _DevicePaneSlot { picture, controls, logcat }

/// Lays the log out first (it was opened on purpose), then the controls in
/// what the picture's share leaves, then gives the picture everything else.
class _DevicePaneLayoutDelegate extends MultiChildLayoutDelegate {
  _DevicePaneLayoutDelegate({required this.pictureMin});

  final double pictureMin;

  @override
  void performLayout(Size size) {
    final width = size.width;
    final rest = math.max(0.0, size.height - pictureMin);
    BoxConstraints below(double maxHeight) =>
        BoxConstraints(minWidth: width, maxWidth: width, maxHeight: maxHeight);

    var logHeight = 0.0;
    if (hasChild(_DevicePaneSlot.logcat)) {
      logHeight = layoutChild(_DevicePaneSlot.logcat, below(rest)).height;
    }
    var controlsHeight = 0.0;
    if (hasChild(_DevicePaneSlot.controls)) {
      controlsHeight = layoutChild(
        _DevicePaneSlot.controls,
        below(math.max(0.0, rest - logHeight)),
      ).height;
    }
    final pictureHeight = math.max(
      0.0,
      size.height - logHeight - controlsHeight,
    );
    layoutChild(
      _DevicePaneSlot.picture,
      BoxConstraints.tight(Size(width, pictureHeight)),
    );
    positionChild(_DevicePaneSlot.picture, Offset.zero);
    if (hasChild(_DevicePaneSlot.controls)) {
      positionChild(_DevicePaneSlot.controls, Offset(0, pictureHeight));
    }
    if (hasChild(_DevicePaneSlot.logcat)) {
      positionChild(
        _DevicePaneSlot.logcat,
        Offset(0, pictureHeight + controlsHeight),
      );
    }
  }

  @override
  bool shouldRelayout(_DevicePaneLayoutDelegate oldDelegate) =>
      oldDelegate.pictureMin != pictureMin;
}
