import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/shell_state.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_store/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
  });
  tearDown(() => db.close());

  /// Pumps the whole app at [size] and returns every error the frame raised.
  Future<List<FlutterErrorDetails>> pumpAt(
    WidgetTester tester,
    Size size, {
    void Function(ProviderContainer container)? prepare,
  }) async {
    final container = fakeTerminalContainer(database: db, data: data);
    addTearDown(container.dispose);
    prepare?.call(container);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const KarmashalaApp(),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previous;
    }
    return errors;
  }

  void widestSaved(ProviderContainer container) {
    container.read(settingsControllerProvider.notifier)
      ..setDebugMode(true)
      ..setDetailSidebarWidth(620)
      ..setExplorerPaneWidth(560);
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.logs);
  }

  group('ShellLayout.allocate', () {
    test('keeps only the rail when the panel cannot fit beside the floor', () {
      final layout = ShellLayout.allocate(
        available: 760,
        explorerColumn: true,
        panelOpen: true,
        explorerWidth: 304,
        panelWidth: 320,
      );
      expect(layout.panelWidth, isNull);
      expect(layout.explorerWidth, 304);
    });

    test('sizes the panel before the Explorer', () {
      final layout = ShellLayout.allocate(
        available: 1000,
        explorerColumn: true,
        panelOpen: true,
        explorerWidth: 560,
        panelWidth: 620,
      );
      expect(layout.explorerWidth, ShellLayout.explorerMin);
      expect(layout.panelWidth, greaterThan(ShellLayout.panelMin));
      expect(layout.clampPanel(9999), layout.panelWidth);
    });
  });

  testWidgets('dragging the side panel wider saves its width', (tester) async {
    late ProviderContainer shell;
    await pumpAt(tester, const Size(1440, 900), prepare: (c) => shell = c);

    final handle = find.bySemanticsLabel('Resize side panel width');
    final before = shell.read(settingsControllerProvider).detailSidebarWidth;
    // The handle is on the leading edge, so dragging it left widens the panel.
    await tester.drag(handle, const Offset(-80, 0));
    await tester.pumpAndSettle();

    expect(
      shell.read(settingsControllerProvider).detailSidebarWidth,
      greaterThan(before),
    );
  });

  for (final width in [760.0, 1000.0, 1180.0]) {
    testWidgets('saved maximum widths leave the workbench its floor at '
        '${width.toInt()} wide', (tester) async {
      final errors = await pumpAt(
        tester,
        Size(width, 800),
        prepare: widestSaved,
      );

      expect(errors.map((e) => '${e.exception}'.split('\n').first), isEmpty);
      expect(
        tester.getSize(find.byType(WorkbenchView)).width,
        greaterThanOrEqualTo(ShellLayout.workbenchFloor),
      );
    });
  }

  for (final width in [760.0, 800.0, 900.0]) {
    testWidgets('default widths leave the workbench its floor at '
        '${width.toInt()} wide', (tester) async {
      final errors = await pumpAt(tester, Size(width, 800));

      expect(errors.map((e) => '${e.exception}'.split('\n').first), isEmpty);
      expect(find.byType(ExplorerPanel), findsOneWidget);
      expect(
        tester.getSize(find.byType(WorkbenchView)).width,
        greaterThanOrEqualTo(ShellLayout.workbenchFloor),
      );
    });
  }

  testWidgets('the compact pane selector grows with the text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final errors = await pumpAt(tester, const Size(640, 900));

    // The title bar above it ran 23px over at this size until its menus fold.
    expect(errors.map((e) => '${e.exception}'.split('\n').first), isEmpty);
    final selector = find.byType(SegmentedButton<ShellPane>);
    expect(selector, findsOneWidget);
    // A fixed 38px bar squeezed the buttons until their labels hung out.
    final label = tester.getRect(find.text('Workbench'));
    expect(label.bottom, lessThanOrEqualTo(tester.getRect(selector).bottom));
  });

  testWidgets('the minimum window with the widest saved panel does not '
      'overflow', (tester) async {
    final errors = await pumpAt(
      tester,
      const Size(720, 560),
      prepare: (container) {
        widestSaved(container);
        container
            .read(shellControllerProvider.notifier)
            .focusPane(ShellPane.detail);
      },
    );

    expect(errors.map((e) => '${e.exception}'.split('\n').first), isEmpty);
    expect(
      tester.getSize(find.byType(WorkbenchView)).width,
      greaterThanOrEqualTo(ShellLayout.workbenchFloor),
    );
  });
}
