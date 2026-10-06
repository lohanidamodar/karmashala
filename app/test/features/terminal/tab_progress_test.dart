import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/tab_progress_sources.dart';
import 'package:karmashala/src/core/util/tab_progress.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_ui/icons.dart';

/// A document tab's header saying how far its page's work has got: a ring
/// and a count while it runs, a mark when some of it failed, and its own
/// glyph again when it is done.
void main() {
  Future<void> pump(WidgetTester tester, TabProgress? progress) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 220,
                child: TerminalTabChip(
                  title: 'Stores',
                  liveness: PaneLiveness.exited,
                  icon: AppIcons.package,
                  progress: progress,
                  selected: false,
                  index: 0,
                  tabCount: 1,
                  onTap: () {},
                  onClose: () {},
                  onEnd: () {},
                  onBulkClose: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets(
    'while it runs: a ring filled as far as it has got, and a count',
    (tester) async {
      await pump(tester, const TabProgress(running: true, done: 3, total: 8));

      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, 3 / 8);
      expect(find.text('3/8'), findsOneWidget);
      expect(find.bySemanticsLabel('Working, 3 of 8'), findsOneWidget);
      expect(find.byIcon(AppIcons.package), findsNothing);
    },
  );

  testWidgets('before it knows how much: a ring that turns, no count', (
    tester,
  ) async {
    await pump(tester, const TabProgress(running: true));

    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, isNull);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets('done with failures: a mark in place of the glyph', (
    tester,
  ) async {
    await pump(tester, const TabProgress(running: false, failed: 2));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('2 failed'), findsOneWidget);
    expect(find.byIcon(AppIcons.warning), findsOneWidget);
  });

  testWidgets('done and quiet: the tab\'s own glyph', (tester) async {
    await pump(tester, null);
    expect(find.byIcon(AppIcons.package), findsOneWidget);

    await pump(tester, const TabProgress(running: false));
    expect(find.byIcon(AppIcons.package), findsOneWidget);
  });

  test('only a page that reports progress has a source', () {
    final container = ProviderContainer(
      overrides: [
        storesTabProgressProvider.overrideWithValue(
          const TabProgress(running: true, done: 1, total: 2),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(documentTabProgressProvider(kStoresPaneId))?.done, 1);
    expect(container.read(documentTabProgressProvider(kUsagePaneId)), isNull);
    expect(container.read(documentTabProgressProvider(kLogsPaneId)), isNull);
  });
}
