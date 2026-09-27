import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/env_secrets/presentation/env_secrets_page.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../support/fake_data_server.dart';

/// The server's environment vault, as Settings shows it (slice 5a): names and
/// when each was set, over `env.*` — never a value, which the app cannot read
/// back at all.
void main() {
  late FakeDataServer server;

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1200, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final data = await server.override();
    final container = ProviderContainer(overrides: [data]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: EnvSecretsPage())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    server = FakeDataServer(clock: () => DateTime.utc(2026, 9, 16));
    server.envVault.seed('GITHUB_TOKEN', 'ghp-never-shown');
  });

  testWidgets('a variable shows that it is set and when, never its value', (
    tester,
  ) async {
    await pump(tester);
    // The same card the snippets and automations pages draw.
    expect(find.byType(ItemCard), findsOneWidget);
    expect(find.text('GITHUB_TOKEN'), findsOneWidget);
    expect(find.text('Set · updated 2026-09-16'), findsOneWidget);
    expect(find.textContaining('ghp-never-shown'), findsNothing);
    expect(server.requests, contains('env.list'));
  });

  testWidgets('removing a variable is confirmed, then asked of the server', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove GITHUB_TOKEN?'), findsOneWidget);
    await tester.tap(find.widgetWithText(DestructiveButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(server.envVault.values, isEmpty);
    expect(find.text('Nothing defined yet.'), findsOneWidget);
  });

  testWidgets('adding one sends the value once and lists only the name', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add variable'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'EDITOR');
    await tester.enterText(find.byType(TextField).last, 'vim');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(server.envVault.values['EDITOR'], 'vim');
    expect(find.text('EDITOR'), findsOneWidget);
    expect(find.text('vim'), findsNothing);
  });

  testWidgets('replacing one keeps the name and sets a new value', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Replace'));
    await tester.pumpAndSettle();
    expect(find.text('Replace GITHUB_TOKEN'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'ghp-new');
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();
    expect(server.envVault.values, {'GITHUB_TOKEN': 'ghp-new'});
  });
}
