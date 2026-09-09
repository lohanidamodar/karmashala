import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_devices/devices.dart' show describeDriveAge;
import '../application/browser_pane_controller.dart';
import '../application/browser_providers.dart';

/// A picture of the whole viewport, and when it was taken.
class BrowserViewportShot {
  const BrowserViewportShot({this.png, this.takenAt, this.problem});

  final Uint8List? png;

  /// When the browser answered. Null until one has been asked for — an
  /// unstamped picture would invite the reader to think it is current.
  final DateTime? takenAt;

  /// Why there is no picture, in the words the service refused with.
  final String? problem;

  bool get isEmpty => png == null && problem == null;
}

/// `browser_screenshot`, for the person at the window.
///
/// The pane could only ever show the **crop** a pick produced: an element, on
/// its own, out of its surroundings. That is the right picture to hand an agent
/// asking about one button and the wrong one for the question a person is
/// usually holding — *what does the page look like right now*.
///
/// The same [BrowserService.screenshot] the tool calls, with no selector: the
/// viewport, which is what the developer is looking at. The full page stays the
/// tool's argument. A pane that offered it would be offering to draw something
/// nobody can see in the window it is drawn in, and the crop beside it already
/// covers "one particular thing".
class BrowserViewportShotController extends Notifier<BrowserViewportShot> {
  @override
  BrowserViewportShot build() => const BrowserViewportShot();

  Future<void> capture() async {
    try {
      final png = await ref.read(browserServiceProvider).screenshot();
      state = BrowserViewportShot(
        png: png,
        takenAt: ref.read(clockProvider).nowUtc(),
      );
    } on Object catch (error) {
      state = BrowserViewportShot(
        problem: '$error',
        takenAt: ref.read(clockProvider).nowUtc(),
      );
    }
  }

  void clear() => state = const BrowserViewportShot();
}

final browserViewportShotProvider =
    NotifierProvider<BrowserViewportShotController, BrowserViewportShot>(
      BrowserViewportShotController.new,
    );

/// The action that takes one.
///
/// Icon-only, and in the console strip rather than beside **Pick element**.
/// That row is a 304px panel with two labelled buttons already in it, and a
/// third overflowed it; the strip below has a flexible field to give space
/// back, so a control added there cannot push anything off the edge.
class BrowserViewportShotButton extends ConsumerWidget {
  const BrowserViewportShotButton({required this.state, super.key});

  final BrowserPaneState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Screenshot the viewport',
    icon: const Icon(AppIcons.image, size: Chrome.iconAction),
    onPressed: state.isConnected && !state.isBusy
        ? () => ref.read(browserViewportShotProvider.notifier).capture()
        : null,
  );
}

/// The picture, with the age of it.
class BrowserViewportShotView extends ConsumerWidget {
  const BrowserViewportShotView({required this.shot, super.key});

  final BrowserViewportShot shot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final png = shot.png;
    final takenAt = shot.takenAt;
    final now = ref.watch(clockProvider).nowUtc();
    return ListView(
      padding: const EdgeInsets.all(Insets.sm),
      children: [
        if (png != null)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Padding(
              padding: const EdgeInsets.all(Insets.xs),
              child: Image.memory(png, fit: BoxFit.contain),
            ),
          ),
        const SizedBox(height: Insets.sm),
        Row(
          children: [
            Expanded(
              child: Text(
                // §19: a picture of a page is true of the moment it was taken,
                // and a page moves on. The age says how much to trust it.
                shot.problem ??
                    'The viewport, '
                        '${takenAt == null ? 'at a time not recorded' : describeDriveAge(now.difference(takenAt))}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: shot.problem == null
                      ? theme.colorScheme.onSurfaceVariant
                      : semantic.attention,
                ),
              ),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(browserViewportShotProvider.notifier).clear(),
              child: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }
}
