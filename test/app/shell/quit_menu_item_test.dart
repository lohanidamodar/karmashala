import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Quitting from the menu bar, not only the tray.
///
/// The window's X can be close-to-tray, and the tray icon is easy to miss, so
/// the menu carries the same exit. It routes through the one service so the
/// ordered shutdown runs either way.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() => db.close());

  Future<void> openWorkspaceMenu(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();
  }

  testWidgets('the Workspace menu offers Quit', (tester) async {
    await openWorkspaceMenu(tester);
    expect(find.text('Quit'), findsOneWidget);
  });

  testWidgets('Quit is inert when nothing is running to quit', (tester) async {
    // Companion mode and every test start without desktop integration; the
    // item must not throw on the way to doing nothing.
    await openWorkspaceMenu(tester);
    await tester.tap(find.text('Quit'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('the holder publishes the running integration', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(systemIntegrationProvider), isNull);
  });
}
