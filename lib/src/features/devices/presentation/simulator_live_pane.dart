import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/ios_device_providers.dart';
import '../application/simulator_live_view.dart';
import '../data/device_gesture_sink.dart';
import '../data/device_keyboard_sink.dart';
import '../domain/simulator_backend.dart';
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
    final name = ref
        .watch(iosSimulatorsProvider)
        .asData
        ?.value
        .where((s) => s.udid == view.udid)
        .map((s) => s.displayName)
        .firstOrNull;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Insets.md, Insets.sm, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name ?? view.udid,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              TextButton(
                key: const Key('stop-simulator-live-view'),
                onPressed: ref.read(simulatorLiveViewProvider.notifier).stop,
                child: const Text('Stop'),
              ),
            ],
          ),
        ),
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
  bool _busy = false;

  Future<void> _run(String what, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) _say('$what failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _press(SimulatorButton button) async {
    final backend = ref.read(simulatorBackendProvider);
    if (backend == null) return;
    await _run(button.name, () => backend.pressButton(widget.udid, button));
  }

  Future<void> _toggleLock() async {
    final backend = ref.read(simulatorBackendProvider);
    if (backend == null) return;
    await _run('Lock', () async {
      final locked = await backend.isLocked(widget.udid);
      await backend.setLocked(widget.udid, locked: !locked);
      if (mounted) setState(() => _locked = !locked);
    });
  }

  Future<void> _appearance() async {
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;
    final wanted = !_dark;
    await _run('Appearance', () async {
      await simctl.setAppearance(widget.udid, wanted ? 'dark' : 'light');
      if (mounted) setState(() => _dark = wanted);
    });
  }

  Future<void> _screenshot() async {
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;
    // The Desktop, because that is where the Simulator's own Cmd+S puts them
    // and it is the one place a person will think to look.
    final home = Platform.environment['HOME'];
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final path = home == null
        ? null
        : '$home/Desktop/Simulator Screen Shot $stamp.png';
    await _run('Screenshot', () async {
      await simctl.screenshot(widget.udid, hostPath: path);
      if (mounted) _say(path == null ? 'Screenshot saved.' : 'Saved to $path');
    });
  }

  Future<void> _openUrl() async {
    final url = await askForSimulatorUrl(context);
    if (url == null || url.trim().isEmpty) return;
    final simctl = ref.read(simctlServiceProvider);
    if (simctl == null) return;
    await _run('Open URL', () => simctl.openUrl(widget.udid, url.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final canPress = ref.watch(simulatorBackendProvider) != null;

    Widget button(
      String tooltip,
      IconData icon,
      VoidCallback? onPressed, {
      Key? key,
    }) => IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: _busy ? null : onPressed,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          button(
            canPress
                ? 'Home'
                : 'Home needs WebDriverAgent, which this build has no copy of',
            AppIcons.circle,
            canPress ? () => _press(SimulatorButton.home) : null,
            key: const Key('simulator-home'),
          ),
          button(
            _locked ? 'Unlock' : 'Lock',
            AppIcons.power,
            canPress ? _toggleLock : null,
            key: const Key('simulator-lock'),
          ),
          button(
            _dark ? 'Switch to light appearance' : 'Switch to dark appearance',
            AppIcons.circleHalf,
            _appearance,
            key: const Key('simulator-appearance'),
          ),
          button(
            'Save a screenshot to the Desktop',
            AppIcons.image,
            _screenshot,
            key: const Key('simulator-screenshot'),
          ),
          button(
            'Open a URL or deep link',
            AppIcons.globe,
            _openUrl,
            key: const Key('simulator-open-url'),
          ),
        ],
      ),
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


/// Asks for a URL to open on the simulator. Null if the dialog was dismissed.
///
/// Extracted so it can be tested on its own — it is the whole of a bug worth a
/// regression test. It holds **no `TextEditingController`**: the first version
/// created one and disposed it as soon as `showDialog` returned, which is after
/// the route pops but *before* its exit animation has finished painting the
/// field. Every frame of that animation then threw "A TextEditingController was
/// used after being disposed", and because the error repeats per frame it took
/// the whole app into an error state rather than failing once.
///
/// Reading the text from `onChanged` needs no controller and so cannot outlive
/// one.
Future<String?> askForSimulatorUrl(BuildContext context) {
  var typed = '';
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open a URL'),
      content: TextField(
        key: const Key('simulator-url-field'),
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'myapp://path, or https://example.com',
        ),
        onChanged: (value) => typed = value,
        onSubmitted: Navigator.of(context).pop,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('simulator-url-open'),
          onPressed: () => Navigator.of(context).pop(typed),
          child: const Text('Open'),
        ),
      ],
    ),
  );
}
