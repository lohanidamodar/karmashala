import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// The strip four panes and the settings screen each drew by hand. Two bugs it
/// must make impossible: the editor's read-only notice overflowed 168px at
/// 240px and its wrapped text squeezed the editor to zero height; and the
/// terminal's status bar gave its label half the free width, because a
/// Flexible sat beside a Spacer.
void main() {
  const message =
      'Read-only: 14.2 MB is too large to edit here without the editor '
      'becoming slow.';

  Widget bar({VoidCallback? onAction, VoidCallback? onDismiss}) =>
      PaneNoticeBar(
        icon: AppIcons.info,
        message: message,
        action: TextButton.icon(
          onPressed: onAction ?? () {},
          icon: const Icon(AppIcons.arrowSquareOut, size: Chrome.iconAction),
          label: const Text('Open in external editor'),
        ),
        onDismiss: onDismiss ?? () {},
      );

  for (final width in [200.0, 240.0, 320.0, 480.0]) {
    for (final scale in sweepScales) {
      testWidgets('fits ${width.toInt()}px at ${scale}x, and both buttons '
          'work', (tester) async {
        var acted = 0;
        var dismissed = 0;
        final overflows = await pumpInBox(
          tester,
          width: width,
          height: 400,
          textScale: scale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bar(onAction: () => acted++, onDismiss: () => dismissed++),
              const Expanded(child: SizedBox(key: ValueKey('editor'))),
            ],
          ),
        );
        expect(overflows, isEmpty);

        final text = tester.widget<Text>(find.text(message));
        expect(text.maxLines, 2);
        expect(
          tester.getSize(find.byKey(const ValueKey('editor'))).height,
          greaterThan(200),
          reason: 'the pane under the notice keeps most of its height',
        );

        await tester.tap(find.text('Open in external editor'));
        await tester.tap(find.byTooltip('Dismiss'));
        expect(acted, 1);
        expect(dismissed, 1);

        final narrow = width < PaneNoticeBar.stackBelow * scale;
        final messageBox = tester.getRect(find.text(message));
        final actionBox = tester.getRect(find.text('Open in external editor'));
        if (narrow) {
          expect(actionBox.top, greaterThanOrEqualTo(messageBox.bottom));
        } else {
          expect(actionBox.left, greaterThan(messageBox.right));
        }
      });
    }
  }

  testWidgets('the message takes all the free width, not half of it', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 800,
      child: const PaneNoticeBar(
        icon: AppIcons.clockCounterClockwise,
        message: 'Restored history',
        action: TextButton(onPressed: null, child: Text('Start')),
      ),
    );
    final messageBox = tester.getRect(find.text('Restored history'));
    final actionBox = tester.getRect(find.byType(TextButton));
    // The message's box runs up to the action, so a longer one would fit.
    expect(
      actionBox.left - messageBox.left,
      greaterThan(800 - actionBox.width - 60),
    );
  });

  testWidgets('each tone draws its own ground and glyph', (tester) async {
    final theme = AppTheme.light();
    final semantic = SemanticColors.forBrightness(Brightness.light);
    final expected = {
      NoticeTone.neutral: theme.colorScheme.onSurfaceVariant,
      NoticeTone.attention: semantic.attention,
      NoticeTone.danger: theme.colorScheme.error,
    };
    final grounds = <Color>{};
    for (final tone in NoticeTone.values) {
      await pumpInBox(
        tester,
        width: 400,
        child: PaneNoticeBar(icon: AppIcons.info, message: 'x', tone: tone),
      );
      expect(tester.widget<Icon>(find.byType(Icon)).color, expected[tone]);
      grounds.add(
        tester
            .widget<Material>(
              find.descendant(
                of: find.byType(PaneNoticeBar),
                matching: find.byType(Material),
              ),
            )
            .color!,
      );
    }
    expect(grounds, hasLength(3));
  });

  testWidgets('without an action or dismiss it is just the message', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 200,
      textScale: 2,
      child: const PaneNoticeBar(icon: AppIcons.info, message: message),
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.text(message), findsOneWidget);
  });

  group('DesktopErrorBanner', () {
    testWidgets('has no dismiss unless asked', (tester) async {
      await pumpInBox(
        tester,
        width: 300,
        child: const DesktopErrorBanner('It failed.'),
      );
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('dismisses when given onDismiss', (tester) async {
      var dismissed = 0;
      final overflows = await pumpInBox(
        tester,
        width: 200,
        textScale: 2,
        child: DesktopErrorBanner(
          'It failed, at some length, for a reason worth reading.',
          onDismiss: () => dismissed++,
        ),
      );
      expect(overflows, isEmpty);
      await tester.tap(find.byTooltip('Dismiss'));
      expect(dismissed, 1);
    });
  });
}
