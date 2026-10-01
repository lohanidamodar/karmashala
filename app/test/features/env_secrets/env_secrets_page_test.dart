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

  Future<void> edit(WidgetTester tester, {String? name, String? value}) async {
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit GITHUB_TOKEN'), findsOneWidget);
    if (name != null) {
      await tester.enterText(find.byType(TextField).first, name);
    }
    if (value != null) {
      await tester.enterText(find.byType(TextField).last, value);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('editing only the value keeps the name and sets a new value', (
    tester,
  ) async {
    await pump(tester);
    await edit(tester, value: 'ghp-new');
    expect(server.envVault.values, {'GITHUB_TOKEN': 'ghp-new'});
  });

  testWidgets('a rename with the value left blank keeps the value, and the '
      'old name is gone', (tester) async {
    await pump(tester);
    await edit(tester, name: 'GH_TOKEN');
    expect(server.envVault.values, {'GH_TOKEN': 'ghp-never-shown'});
    expect(server.requests, contains('env.rename'));
    expect(find.text('GH_TOKEN'), findsOneWidget);
    expect(find.text('GITHUB_TOKEN'), findsNothing);
  });

  testWidgets('a rename and a new value land together', (tester) async {
    await pump(tester);
    await edit(tester, name: 'GH_TOKEN', value: 'ghp-new');
    expect(server.envVault.values, {'GH_TOKEN': 'ghp-new'});
  });

  testWidgets('a rename onto another variable is refused, nothing changed', (
    tester,
  ) async {
    server.envVault.seed('OTHER', 'kept');
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Edit').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'OTHER');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('OTHER is already set'), findsOneWidget);
    expect(server.envVault.values, {
      'GITHUB_TOKEN': 'ghp-never-shown',
      'OTHER': 'kept',
    });
  });
}
