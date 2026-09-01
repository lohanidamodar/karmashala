import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
            child: Video(
              controller: view.controller,
              // `contain`, not `fill`: the picture's aspect ratio is the
              // device's, and stretching it to the pane would make every
              // proportion on screen a lie about what the app looks like.
              fit: BoxFit.contain,
              controls: NoVideoControls,
            ),
          ),
        ),
      ],
    );
  }
}
