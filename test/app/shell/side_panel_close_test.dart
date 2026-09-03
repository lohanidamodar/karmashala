import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/pane_scaffold.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **Every side-panel surface closes the same way.**
///
/// The panel holds two kinds of surface: six that let it draw their header, and
/// five that draw their own (`drawsOwnHeader`) with actions built from their own
/// providers. Only the first six used to get a close button, so half the panel
/// could be dismissed from the header and half could only be dismissed from the
/// rail — the same glyph you opened it with, which is not where anyone looks
/// for a way out.
///
/// The fix hands the button *down* through [PaneCloseAction] rather than
/// pulling five features' actions up into the panel. `drawsOwnHeader` still
/// means what it says — whether the panel stacks a header of its own — and the
/// panel still watches nothing on those five features' behalf.
void main() {
  /// Settle, but do not require the tree to go quiet: a surface that is still
  /// probing draws a progress indicator, and `pumpAndSettle` would time the
  /// whole sweep out rather than look at the header in front of it. The same
  /// tolerance `window_matrix.dart` takes, for the same reason.
  Future<void> settle(WidgetTester tester) async {
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
    } on FlutterError catch (error) {
      if (!error.message.contains('pumpAndSettle timed out')) rethrow;
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The panel's own close button, wherever it was drawn.
  final closeButton = find.byWidgetPredicate(
    (w) => w is IconButton && (w.tooltip?.startsWith('Close panel') ?? false),
    description: 'the panel close button',
  );

  group('PaneCloseAction', () {
    Widget header({required bool inPanel}) {
      const bare = PaneHeader(
        icon: AppIcons.folder,
        title: 'Files',
        actions: [Icon(AppIcons.arrowsClockwise)],
      );
      return MaterialApp(
        home: Scaffold(
          body: inPanel
              ? PaneCloseAction(
                  tooltip: 'Close panel',
                  onClose: () {},
                  child: bare,
                )
              : bare,
        ),
      );
    }

    testWidgets('a header outside a panel wears no close button', (
      tester,
    ) async {
      // A workbench pane closes from its tab. A close glyph in its header
      // would be a second, differently-scoped way to do it.
      await tester.pumpWidget(header(inPanel: false));
      expect(closeButton, findsNothing);
    });

    testWidgets('a header inside a panel wears one, after its own actions', (
      tester,
    ) async {
      await tester.pumpWidget(header(inPanel: true));
      expect(closeButton, findsOneWidget);
      expect(
        tester.getCenter(closeButton).dx,
        greaterThan(
          tester.getCenter(find.byIcon(AppIcons.arrowsClockwise)).dx,
        ),
        reason: 'the way out belongs in the corner, past what the surface owns',
      );
    });
  });

  testWidgets('every offered surface can be closed from its header', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle(tester);

    final panel = container.read(sidePanelProvider.notifier);
    // Debug mode off, so this is the rail a user actually sees; the Logs
    // surface is a diagnostic and is not offered.
    final offered = SidePanelSurface.offered(debugMode: false);
    expect(offered.where((s) => s.drawsOwnHeader).length, 6);
    expect(offered.where((s) => !s.drawsOwnHeader).length, greaterThan(0));

    for (final surface in offered) {
      panel.select(surface);
      await settle(tester);
      expect(
        container.read(sidePanelProvider),
        surface,
        reason: '${surface.label} is open',
      );
      expect(
        closeButton,
        findsOneWidget,
        reason:
            '${surface.label} offers exactly one way out of the panel from '
            'its header, whether the header is its own or the panel\'s',
      );

      await tester.tap(closeButton);
      await settle(tester);
      expect(
        container.read(sidePanelProvider),
        isNull,
        reason: 'closing from ${surface.label} collapses the panel',
      );
      expect(closeButton, findsNothing, reason: 'and the body is gone with it');
    }
  });
}
