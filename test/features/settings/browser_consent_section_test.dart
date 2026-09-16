import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/browser/application/browser_consent_providers.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/settings/presentation/tools_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The human half of the consent gate.
///
/// A gate with no reachable way to say yes is a feature that is simply off, so
/// this is not decoration: it is the only path by which `browser_evaluate` ever
/// becomes available, and the only place a grant can be taken back.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    ProjectDao(db).insert(project(id: 'p2', name: 'Other', path: r'C:\src\o'));
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: BrowserConsentSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('every project is listed, and none is allowed by default', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('Demo'), findsOneWidget);
    expect(find.textContaining('Other'), findsOneWidget);
    for (final widget in tester.widgetList<Switch>(find.byType(Switch))) {
      expect(widget.value, isFalse);
    }
    expect(find.textContaining('Not allowed'), findsNWidgets(2));
  });

  testWidgets('the switch records a grant for that project alone', (
    tester,
  ) async {
    final container = await pump(tester);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    final store = container.read(browserConsentStoreProvider);
    expect(store.isGranted('p1', BrowserCapability.evaluate), isTrue);
    expect(store.isGranted('p2', BrowserCapability.evaluate), isFalse);
    // The row now says when, not just that — a grant with no date is a
    // permission nobody can audit.
    expect(find.textContaining('Allowed since'), findsOneWidget);
  });

  testWidgets('turning it off revokes it', (tester) async {
    final container = await pump(tester);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(
      container
          .read(browserConsentStoreProvider)
          .isGranted('p1', BrowserCapability.evaluate),
      isFalse,
    );
    expect(find.textContaining('Allowed since'), findsNothing);
  });

  testWidgets('the section says what the grant actually permits', (
    tester,
  ) async {
    await pump(tester);
    // The person clicking this has to understand that it is not "let the agent
    // use the browser" — the reading tools already work.
    expect(find.textContaining('browser_evaluate'), findsWidgets);
    expect(find.textContaining('cookies'), findsWidgets);
  });
}
