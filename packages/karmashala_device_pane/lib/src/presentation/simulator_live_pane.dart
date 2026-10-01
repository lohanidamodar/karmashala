import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/device_recording_controller.dart';
import '../application/ios_device_providers.dart';
import '../application/simulator_live_view.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'device_controls.dart';
import 'device_keyboard_surface.dart';
import 'device_recording_indicator.dart';
import 'device_state_dialog.dart';
import 'device_touch_surface.dart';

/// The simulator's picture, when there is one. Draws nothing when nothing is
/// mirrored, so the pane falls through without this having an opinion.
class SimulatorLivePane extends ConsumerWidget {
  const SimulatorLivePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(simulatorLiveViewProvider);
    final controller = ref.read(simulatorLiveViewProvider.notifier);

    return switch (state) {
      SimulatorLiveViewIdle() => const SizedBox.shrink(),
      // Named, because twenty seconds of spinner reads as a hang: WDA is
      // installed into the simulator, launched, then bootstraps.
      SimulatorLiveViewStarting() => const PanePlaceholder(
        message:
            'Starting the live view\n\n'
            'WebDriverAgent is starting inside the simulator. '
            'This takes about 20 seconds the first time.',
        action: InlineSpinner(
          size: InlineSpinnerSize.large,
          semanticsLabel: 'Starting the live view',
        ),
      ),
      SimulatorLiveViewFailed(:final reason) => PanePlaceholder(
        icon: AppIcons.warningCircle,
        message: 'The live view would not start\n\n$reason',
        action: TextButton(
          onPressed: controller.stop,
          child: const Text('Dismiss'),
        ),
      ),
      SimulatorLiveViewRunning(:final view) => _Running(view: view),
    };
  }
}

class _Running extends ConsumerWidget {
  const _Running({required this.view});

  final SimulatorLiveView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screen = view.screen;
    final backend = ref.watch(simulatorBackendProvider);
    // The pane draws no name and no Stop of its own — the toolbar carries
    // both. The name is read for the keyboard surface, which says whose.
    final name = ref
        .watch(iosSimulatorsProvider)
        .asData
        ?.value
        .where((s) => s.udid == view.udid)
        .map((s) => s.displayName)
        .firstOrNull;
    return Column(
      children: [
        Expanded(
          // The same surface the Android pane uses, given a different sink:
          // focus, arming and the escape chord stay in one place.
          child: DeviceKeyboardSurface(
            sink: backend == null
                ? null
                : SimulatorKeyboardSink(
                    backend: backend,
                    udid: view.udid,
                    onError: (error) => ref
                        .read(simulatorInputErrorProvider.notifier)
                        .report('$error'),
                  ),
            deviceLabel: name ?? view.udid,
            child: Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: screen == null
                  // No size from the backend, so no input — but still the
                  // picture's own shape, never the pane's.
                  ? Center(child: _video(view, shaped: true))
                  : AspectRatio(
                      // The touch surface treats its box **as** the picture,
                      // so it must be that, not the letterbox around it.
                      aspectRatio: screen.points.width / screen.points.height,
                      child: DeviceTouchSurface(
                        sink: SimulatorGestureSink(
                          backend: backend!,
                          udid: view.udid,
                          screen: screen.points,
                          onError: (error) => ref
                              .read(simulatorInputErrorProvider.notifier)
                              .report('$error'),
                        ),
                        // iOS has no pinch through this transport: WDA takes
                        // one action sequence per gesture.
                        pinchWithModifier: false,
                        child: _video(view),
                      ),
                    ),
            ),
          ),
        ),
        _SimulatorControls(udid: view.udid),
      ],
    );
  }
}

/// The controls Simulator.app's Device and Features menus offer, for a
/// simulator with no window. No rotation: tap mapping is fixed at view start.
class _SimulatorControls extends ConsumerStatefulWidget {
  const _SimulatorControls({required this.udid});

  final String udid;

  @override
  ConsumerState<_SimulatorControls> createState() => _SimulatorControlsState();
}

class _SimulatorControlsState extends ConsumerState<_SimulatorControls> {
  /// What this pane last *set*, not what the device reports: reading
  /// `simctl ui appearance` back costs a process spawn.
  bool _dark = false;

  /// What the last toggle left the device in. Re-read before every toggle, so a
  /// device locked from somewhere else cannot leave the button inverted.
  bool _locked = false;

  Future<void> _press(SimulatorButton button) async {
    final backend = ref.read(simulatorBackendProvider);
    if (backend == null) return;
    await backend.pressButton(widget.udid, button);
  }

  Future<void> _toggleLock() async {
    final backend = ref.read(simulatorBackendProvider);
    if (backend == null) return;
    final locked = await backend.isLocked(widget.udid);
    await backend.setLocked(widget.udid, locked: !locked);
    if (mounted) setState(() => _locked = !locked);
  }

  Future<void> _appearance() async {
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;
    // Asked, not remembered: a local flag starting at light darkened an
    // already dark simulator, and a rebuild left the button inverted.
    final wanted = !(await simctl.isDarkAppearance(widget.udid) ?? _dark);
    await simctl.setAppearance(widget.udid, wanted ? 'dark' : 'light');
    if (mounted) setState(() => _dark = wanted);
  }

  Future<void> _screenshot() async {
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;
    final path = desktopScreenshotPath('Simulator');
    await simctl.screenshot(widget.udid, hostPath: path);
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(path == null ? 'Screenshot saved.' : 'Saved to $path'),
        ),
      );
    }
  }

  Future<void> _openUrl() async {
    final url = await askForDeviceUrl(context);
    if (url == null || url.trim().isEmpty) return;
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;
    await simctl.openUrl(widget.udid, url.trim());
  }

  Future<void> _deviceSettings() async {
    final simctl = ref.read(simctlServiceProvider);
    final target = _target;
    if (simctl == null || target == null) return;
    final driver = SimulatorDeviceDriver(
      simctl: simctl,
      backend: null,
      target: target,
    );
    await showDeviceStateDialog(
      context,
      deviceLabel: target.label,
      apply: driver.changeState,
    );
  }

  /// The recorder needs the simulator, not only its udid: the file is named
  /// after [DeviceTarget.fileSafeId] and the banner after its label.
  SimulatorTarget? get _target {
    final simulator = ref
        .watch(bootedSimulatorsProvider)
        .where((s) => s.udid == widget.udid)
        .firstOrNull;
    return simulator == null ? null : SimulatorTarget(simulator);
  }

  @override
  Widget build(BuildContext context) {
    final canPress = ref.watch(simulatorBackendProvider) != null;
    final recording = ref.watch(deviceRecordingProvider);
    final target = _target;
    // `simctl` is what records, and it is null on any host without Xcode —
    // the same gate every other simulator verb uses.
    final canRecord =
        target != null && ref.watch(simctlServiceProvider) != null;

    // Rebuilt each second while recording, for the elapsed time on Stop.
    return RecordingClock(
      recording: recording,
      builder: (context, now) => DeviceControlBar(
        controls: [
          DeviceControl(
            name: 'Home',
            tooltip: canPress
                ? 'Home'
                : 'Home needs WebDriverAgent, which this build has no copy of',
            icon: AppIcons.house,
            onPressed: canPress ? () => _press(SimulatorButton.home) : null,
            buttonKey: const Key('simulator-home'),
          ),
          DeviceControl(
            name: 'Lock',
            tooltip: _locked ? 'Unlock' : 'Lock',
            // A padlock, selected while locked: [AppIcons.power] is the
            // toolbar's shut-down, and this only sleeps the screen.
            icon: AppIcons.lockSimple,
            selected: _locked,
            onPressed: canPress ? _toggleLock : null,
            buttonKey: const Key('simulator-lock'),
          ),
          DeviceControl(
            name: 'Appearance',
            tooltip: _dark
                ? 'Switch to light appearance'
                : 'Switch to dark appearance',
            icon: AppIcons.moon,
            selected: _dark,
            onPressed: _appearance,
            buttonKey: const Key('simulator-appearance'),
          ),
          DeviceControl(
            name: 'Screenshot',
            tooltip: 'Save a screenshot to the Desktop',
            icon: AppIcons.camera,
            onPressed: _screenshot,
            buttonKey: const Key('simulator-screenshot'),
          ),
          DeviceControl(
            name: 'Open URL',
            tooltip: 'Open a URL or deep link',
            icon: AppIcons.globe,
            onPressed: _openUrl,
            buttonKey: const Key('simulator-open-url'),
          ),
          DeviceControl(
            name: 'Device settings',
            tooltip: 'Font scale, locale and permissions',
            icon: AppIcons.gearSix,
            onPressed: canRecord ? _deviceSettings : null,
            buttonKey: const Key('simulator-device-settings'),
          ),
          // `simctl io … recordVideo`, not a tee of the picture above: that is
          // WebDriverAgent's MJPEG, screenshots with no encoded video behind it.
          DeviceControl(
            name: 'Record',
            tooltip: recording is DeviceRecordingActive
                ? stopRecordingTooltip(recording, now)
                : canRecord
                ? 'Start recording the screen to a QuickTime (.mov) file'
                : 'Recording a simulator needs simctl, which is macOS only',
            // Record in the failure colour, and a solid stop square while it
            // runs — neither is used by any other control in the pane.
            icon: recording is DeviceRecordingActive
                ? AppIcons.stopFill
                : AppIcons.record,
            color: recording is DeviceRecordingActive
                ? null
                : SemanticColors.of(context).failure,
            selected: recording is DeviceRecordingActive,
            onPressed: recording is DeviceRecordingActive
                ? ref.read(deviceRecordingProvider.notifier).stop
                : canRecord
                ? () => ref
                      .read(deviceRecordingProvider.notifier)
                      .startSimulatorRecording(target)
                : null,
            buttonKey: const Key('simulator-record'),
          ),
        ],
      ),
    );
  }
}

/// The shape a simulator's picture is given before anything says otherwise:
/// an iPhone's, the same default the Android picture uses.
const double _defaultSimulatorAspect = 9 / 19.5;

/// Paints the newest decoded frame with a plain [RawImage]: media_kit's libmpv
/// has no `mpjpeg` demuxer, so WebDriverAgent's stream is decoded in Dart.
///
/// [shaped] is for when no screen size is known: the frame's own proportions,
/// or [_defaultSimulatorAspect] until one arrives, instead of `BoxFit.fill`
/// into whatever box the pane has.
Widget _video(SimulatorLiveView view, {bool shaped = false}) =>
    ValueListenableBuilder<ui.Image?>(
      valueListenable: view.frames.image,
      builder: (context, image, _) {
        final Widget picture = image == null
            // Until the first frame decodes, which is a fraction of a second
            // after the stream opens.
            ? const ColoredBox(color: Colors.black)
            : RawImage(
                image: image,
                fit: BoxFit.fill,
                // The frames are already device pixels. Leaving this at the
                // window's ratio would ask Flutter to shrink them again on a
                // Retina display.
                scale: 1,
                // Bilinear, not `medium`: `medium` builds mipmaps, and every
                // frame here is a *new* image — thirty regenerations a second.
                filterQuality: FilterQuality.low,
              );
        if (!shaped) return picture;
        return AspectRatio(
          aspectRatio: image == null || image.height == 0
              ? _defaultSimulatorAspect
              : image.width / image.height,
          child: picture,
        );
      },
    );
