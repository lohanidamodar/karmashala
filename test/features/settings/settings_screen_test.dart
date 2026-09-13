import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The master-detail settings screen: section switching by mouse and by
/// keyboard, the filter, deep links, and the compact drill-down — the whole
/// information architecture Loop 79 replaced the single long column with.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    // The Terminal page resolves the default shell against the environments,
    // and an empty list has no shell to resolve to.
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() => db.close());

  ProviderContainer prepared() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // Theme discovery reads real Ghostty/Warp directories.
        discoveredTerminalThemesProvider.overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    SettingsSectionId? section,
  }) async {
    final container = prepared();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: SettingsScreen(initialSection: section)),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Tabs until a nav *row* holds focus — inside the nav, but not the filter
  /// field (whose focus sits under an EditableText).
  Future<void> focusANavRow(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) continue;
      var inNav = false;
      var inEditable = false;
      context.visitAncestorElements((element) {
        if (element.widget is EditableText) inEditable = true;
        if (element.widget is SettingsNav) {
          inNav = true;
          return false;
        }
        return true;
      });
      if (inNav && !inEditable) return;
    }
    fail('tab never reached a settings nav row');
  }

  testWidgets('desktop: nav beside content, switching by click', (
    tester,
  ) async {
    await pump(tester);

    // Lands on Appearance, with the nav alongside.
    expect(find.byType(SettingsNav), findsOneWidget);
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('UI text size'), findsOneWidget);

    await tester.tap(find.text('Terminal'));
    await tester.pumpAndSettle();

    expect(find.text('DEFAULT TERMINAL'), findsOneWidget);
    expect(find.text('TERMINAL CHORDS'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsNothing);
    // The nav stays put after the switch — master-detail, not navigation.
    expect(find.byType(SettingsNav), findsOneWidget);
  });

  testWidgets('keyboard: arrows move the selection from a focused row', (
    tester,
  ) async {
    await pump(tester);
    await focusANavRow(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('SYSTEM'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('DEFAULT TERMINAL'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.text('SYSTEM'), findsOneWidget);
  });

  testWidgets('the filter narrows the nav to matching sections', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField).first, 'known hosts');
    await tester.pumpAndSettle();

    // Only Environments mentions known hosts — the SSH page was folded into
    // it, hosts and all — and the rest of the rail is gone.
    expect(find.text('Environments'), findsOneWidget);
    expect(find.text('Permissions'), findsNothing);

    await tester.tap(find.text('Environments'));
    await tester.pumpAndSettle();
    expect(find.text('TRUSTED HOST KEYS'), findsOneWidget);
  });

  testWidgets('a deep link lands on the requested section', (tester) async {
    await pump(tester, section: SettingsSectionId.agents);
    expect(find.text('DEFAULT AGENT'), findsOneWidget);
    expect(find.text('CLAUDE ACCOUNTS'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsNothing);
  });

  testWidgets('phone: the nav is the page, sections drill in and back out', (
    tester,
  ) async {
    await pump(tester, size: const Size(390, 844));

    // The list first — no section content yet.
    expect(find.text('APPEARANCE'), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);

    await tester.tap(find.text('Terminal'));
    await tester.pumpAndSettle();
    expect(find.text('DEFAULT TERMINAL'), findsOneWidget);
    expect(find.text('Settings · Terminal'), findsOneWidget);
    expect(find.byType(SettingsNav), findsNothing);

    // Back returns to the list, not out of Settings.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsNav), findsOneWidget);
    expect(find.text('DEFAULT TERMINAL'), findsNothing);
  });

  testWidgets('the terminal font size row steps, resets and persists', (
    tester,
  ) async {
    final container = await pump(
      tester,
      section: SettingsSectionId.terminal,
    );

    await tester.tap(find.byTooltip('Larger terminal font'));
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).terminalFontSize, 14.0);

    // Off the default, so the way back appears — and works.
    await tester.tap(find.byTooltip('Reset terminal font size'));
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).terminalFontSize, 13.0);
    expect(find.byTooltip('Reset terminal font size'), findsNothing);

    await tester.tap(find.byTooltip('Smaller terminal font'));
    await tester.pumpAndSettle();
    expect(container.read(settingsControllerProvider).terminalFontSize, 12.0);
  });
}
