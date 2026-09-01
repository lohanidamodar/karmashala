import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;


import '../data/device_gesture_sink.dart';
import 'device_touch_surface.dart';

import '../../../app/theme/design_tokens.dart';
import '../application/ios_device_providers.dart';
import '../application/simulator_live_view.dart';

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
      filterQuality: FilterQuality.medium,
    );
  },
);
