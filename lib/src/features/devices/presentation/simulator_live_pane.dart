import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/device_recording_controller.dart';
import '../application/ios_device_providers.dart';
import '../application/simulator_live_view.dart';
import '../data/device_gesture_sink.dart';
import '../data/device_keyboard_sink.dart';
import '../domain/device_recording.dart';
import '../domain/device_target.dart';
import '../domain/simulator_backend.dart';
import 'device_controls.dart';
import 'device_keyboard_surface.dart';
import 'device_touch_surface.dart';

/// The simulator's picture, when there is one.
///
/// Returns null from [maybeBuild] when nothing is being mirrored, so the pane
/// can fall through to the Android live view or the device list without this
/// having an opinion about either.
class SimulatorLivePane extends ConsumerWidget {
  const SimulatorLivePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(simulatorLiveViewProvider);
    final controller = ref.read(simulatorLiveViewProvider.notifier);
    final theme = Theme.of(context);

    return switch (state) {
      SimulatorLiveViewIdle() => const SizedBox.shrink(),
      SimulatorLiveViewStarting() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: Insets.md),
            Text('Starting the live view', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            // Named, because seventeen seconds of spinner with no explanation
            // reads as a hang. WebDriverAgent is installed into the simulator,
            // launched, and then has to bootstrap XCTest.
            Text(
              'WebDriverAgent is starting inside the simulator. '
              'This takes about 20 seconds the first time.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
      SimulatorLiveViewFailed(:final reason) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The live view would not start',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                reason,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              TextButton(
                onPressed: controller.stop,
                child: const Text('Dismiss'),
              ),
            ],
          ),
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
    // The pane draws no name and no Stop of its own: the toolbar above carries
    // both, and showing them twice put two "iPhone 16 Pro · iOS 18.2" rows and
    // two Stop buttons on screen, one under the other. The device it is a
    // picture *of* is the toolbar's job, the same way the Android live view
    // leaves it there.
    //
    // The name is still read, because the keyboard surface says whose keyboard
    // it has taken — "Sending keys to iPhone 16 Pro" is the whole point of that
    // line, and a udid there would tell the user nothing.
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
          // The same surface the Android pane uses, given a different sink.
          // Focus, arming, the escape chord and the wording all live in there,
          // which is what stops the two platforms drifting apart: the only
          // thing this side chooses is what a keystroke means on the wire.
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
                  ? _video(view)
                  : AspectRatio(
                      // The touch surface treats its box **as** the picture — it
                      // maps a widget point to a 0..1 fraction of it — so the box
                      // has to be exactly the picture and not the letterboxed
                      // area around it. `BoxFit.fill` inside a correctly-shaped
                      // box is the same image as `contain` in a loose one, and it
                      // is the only version a tap can be mapped through.
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
                        // iOS has no pinch through this transport: WebDriverAgent
                        // takes one action sequence per gesture, and the Ctrl-drag
                        // mirror trick is scrcpy's.
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

/// The controls the Simulator's own Device and Features menus offer, for a
/// simulator with no window of its own.
///
/// Home and Lock go through WebDriverAgent, which is the only thing here that
/// can press a physical button. Everything else is `simctl`, which is why the
/// row can offer appearance and deep links that a real device's buttons cannot.
///
/// Rotation is deliberately absent. WebDriverAgent can ask for an orientation,
/// but the picture's aspect ratio is read once when the view starts and the tap
/// mapping is derived from it — so rotating would leave every tap landing in
/// the wrong place until the view was restarted. It needs the view to follow a
/// size change, which is more than a button.
///
/// The busy gate, the failure snackbar and the row itself now live in
/// [DeviceControlBar], shared with the Android row: those manners are the same
/// on both platforms, and keeping two copies is how the Android row ended up
/// without any of them. What is left here is the part that is genuinely iOS —
/// which commands to send, and the two pieces of state the buttons name
/// themselves after.
class _SimulatorControls extends ConsumerStatefulWidget {
  const _SimulatorControls({required this.udid});

  final String udid;

  @override
  ConsumerState<_SimulatorControls> createState() => _SimulatorControlsState();
}

class _SimulatorControlsState extends ConsumerState<_SimulatorControls> {
  /// What this pane last *set*, not what the device reports.
  ///
  /// `simctl ui appearance` can be read back, but only by spawning a process,
  /// and the answer is only ever wrong if something outside this app changed it.
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
    // Asked, not remembered — the same way the Android control does it. The
    // local flag started at light, so a simulator already dark went dark again
    // on the first press, and a rebuild of this row reset the flag and left the
    // device stuck in dark with the button offering to darken it further.
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

    return DeviceControlBar(
      controls: [
        DeviceControl(
          name: 'Home',
          tooltip: canPress
              ? 'Home'
              : 'Home needs WebDriverAgent, which this build has no copy of',
          icon: AppIcons.circle,
          onPressed: canPress ? () => _press(SimulatorButton.home) : null,
          buttonKey: const Key('simulator-home'),
        ),
        DeviceControl(
          name: 'Lock',
          tooltip: _locked ? 'Unlock' : 'Lock',
          icon: AppIcons.power,
          onPressed: canPress ? _toggleLock : null,
          buttonKey: const Key('simulator-lock'),
        ),
        DeviceControl(
          name: 'Appearance',
          tooltip: _dark
              ? 'Switch to light appearance'
              : 'Switch to dark appearance',
          icon: AppIcons.circleHalf,
          onPressed: _appearance,
          buttonKey: const Key('simulator-appearance'),
        ),
        DeviceControl(
          name: 'Screenshot',
          tooltip: 'Save a screenshot to the Desktop',
          icon: AppIcons.image,
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
        // `simctl io … recordVideo`, not a tee of the picture above: that
        // picture is WebDriverAgent's MJPEG, a feed of screenshots with no
        // encoded video behind it, while simctl records the display itself and
        // writes a QuickTime movie.
        DeviceControl(
          name: 'Record',
          tooltip: recording is DeviceRecordingActive
              ? 'Stop recording'
              : canRecord
              ? 'Record the screen to a QuickTime (.mov) file'
              : 'Recording a simulator needs simctl, which is macOS only',
          icon: recording is DeviceRecordingActive
              ? AppIcons.stopCircle
              : AppIcons.circle,
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
    );
  }
}

/// The picture itself.
/// Paints the newest decoded frame.
///
/// A plain [RawImage] rather than a video widget: the picture is a stream of
/// JPEGs decoded in [SimulatorFrames], because media_kit's libmpv has no
/// `mpjpeg` demuxer and cannot read WebDriverAgent's stream at all. Rebuilds
/// are scoped to the notifier, so a new frame repaints the image and nothing
/// else in the pane.
///
/// `BoxFit.fill`, because every caller sizes the box to the device's aspect
/// ratio first. The touch surface can only map a tap if its box *is* the
/// picture rather than the letterboxed area around it, and `fill` inside a
/// correctly-shaped box is the same image `contain` would draw in a loose one.
Widget _video(SimulatorLiveView view) => ValueListenableBuilder<ui.Image?>(
  valueListenable: view.frames.image,
  builder: (context, image, _) {
    if (image == null) {
      // Until the first frame decodes, which is a fraction of a second after
      // the stream opens.
      return const ColoredBox(color: Colors.black);
    }
    return RawImage(
      image: image,
      fit: BoxFit.fill,
      // The frames are already device pixels. Leaving this at the window's
      // ratio would ask Flutter to shrink them again on a Retina display.
      scale: 1,
      // Bilinear, not `medium`. `medium` builds mipmaps, and every frame here
      // is a *new* image — so it was regenerating them thirty times a second
      // for a picture that is only ever scaled down a little.
      filterQuality: FilterQuality.low,
    );
  },
);
