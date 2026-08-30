import 'package:chitragupta/src/app/chitragupta_app.dart';
import 'package:chitragupta/src/app/shell/resize_handle.dart';
import 'package:chitragupta/src/app/shell/shell_state.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() => db.close());

  // The panels read the database; provide an in-memory one.
  Future<void> pumpApp(WidgetTester tester, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const ChitraguptaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wide layout shows the explorer and detail panes', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1600, 900));

    // The app bar reads like a native menu bar (no app icon/name — the OS title
    // bar carries those).
    expect(find.byType(AppBar), findsOneWidget);
    // Pane headers render as tracked "ledger tab" labels (uppercased).
    expect(find.text('EXPLORER'), findsOneWidget);
    expect(find.text('DETAIL'), findsOneWidget);
    // Workspace tools stay available before a project/repository is selected.
    expect(find.text('Device'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
  });

  testWidgets('narrow layout shows a single pane with a selector', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(640, 900));

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(SegmentedButton<ShellPane>), findsOneWidget);
  });

  testWidgets('the terminal dock can be resized and maximized', (tester) async {
    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ChitraguptaApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Toggle terminal (Ctrl+`)'));
    await tester.pumpAndSettle();
    final initial = tester.getSize(find.byType(TerminalPanel)).height;
    expect(initial, greaterThan(0));

    // Dragging the dock's handle upward makes the terminal taller.
    final handle = find.byWidgetPredicate(
      (w) => w is ResizeHandle && w.axis == Axis.vertical,
    );
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(TerminalPanel)).height,
      closeTo(initial + 100, 2),
    );

    // Maximizing gives it the whole body.
    await tester.tap(find.byTooltip('Maximize terminal'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(TerminalPanel)).height,
      greaterThan(initial * 2),
    );
  });
}
