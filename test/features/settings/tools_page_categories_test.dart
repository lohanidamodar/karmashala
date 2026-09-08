import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/presentation/tools_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The Tools page as a page rather than as four stacked blocks.
///
/// The complaint that started this was that the page is a wall: a terminal
/// picker, an editor picker, a bridge verdict and a consent switch, with
/// nothing saying which of them answer the same question. The headings are the
/// answer, so a missing one is a regression rather than a styling change.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(posixEnv());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ToolsPage())),
        ),
      ),
    );
    await tester.pump();
  }

  for (final (name, size) in const [
    ('phone', Size(390, 844)),
    ('desktop', Size(1440, 900)),
  ]) {
    testWidgets('every category is headed at $name width', (tester) async {
      await pump(tester, size);
      for (final heading in ToolsPage.categories) {
        expect(
          find.text(heading),
          findsOneWidget,
          reason: '$heading has no heading on the page',
        );
      }
    });
  }

  testWidgets('the controls the headings organise are all still there', (
    tester,
  ) async {
    // Organisation, not redesign: the page keeps the two pickers, the bridge
    // check and the consent block it had before the bands existed.
    await pump(tester, const Size(1440, 900));
    expect(find.text('Open sessions in'), findsOneWidget);
    expect(find.text('Open folders in'), findsOneWidget);
    expect(find.textContaining('Check the bridge'), findsOneWidget);
    expect(find.textContaining('browser_evaluate runs whatever'), findsOneWidget);
  });
}
