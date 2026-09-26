import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The title bar's controls are drawn from [Chrome], not from numbers of their
/// own, and the one half-destructive menu command confirms like one.
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

  Future<void> pumpApp(WidgetTester tester) async {
    final container = fakeTerminalContainer(database: db, data: data);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the title bar controls are Chrome.control tall', (tester) async {
    await pumpApp(tester);

    expect(tester.getSize(find.byType(QuickOpenButton)).height, Chrome.control);
    final settings = find.descendant(
      of: find.byType(ShellTitleBar),
      matching: find.bySemanticsLabel('Settings'),
    );
    expect(tester.getSize(settings), const Size.square(Chrome.control));
    expect(tester.getSize(find.text('Workspace')).height, lessThan(30));
  });

  testWidgets('clearing and re-importing confirms with a destructive button', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear projects and re-import'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(DestructiveButton, 'Clear and re-import'),
      findsOneWidget,
    );
    expect(find.byType(BoundedDialogContent), findsOneWidget);
  });
}
