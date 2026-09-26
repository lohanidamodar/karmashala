import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/editor/application/code_editor_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/settings/presentation/settings_row.dart';
import 'package:karmashala/src/features/settings/presentation/side_panel_items_section.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import 'package:agent_cli/process.dart';

/// Settings › Appearance › Side panel: the rail's checklist where a person who
/// never right-clicks the rail will look for it.
void main() {
  late FakeDataServer server;

  Future<ProviderContainer> prepared() async {
    server = FakeDataServer(clock: () => testTime);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        data,
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
        availableSystemTerminalsProvider.overrideWith((ref) async => const []),
        availableCodeEditorsProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget app(ProviderContainer container, Widget home) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: home, debugShowCheckedModeBanner: false),
      );

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(1440, 900),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await prepared();
    await tester.pumpWidget(app(container, home));
    await tester.pumpAndSettle();
    return container;
  }

  Finder row(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(SidePanelSurfaceCheckRow),
  );

  bool checked(WidgetTester tester, String label) => tester
      .widget<Checkbox>(
        find.descendant(of: row(label), matching: find.byType(Checkbox)),
      )
      .value!;

  List<String> stored() =>
      SettingsRepository(server.store).load().hiddenSidePanelSurfaces;

  testWidgets('the Explorer\'s project details are a switch here, on until '
      'turned off', (tester) async {
    final container = await pump(
      tester,
      const Scaffold(
        body: SingleChildScrollView(child: SidePanelItemsSection()),
      ),
    );
    final toggle = find.descendant(
      of: find.ancestor(
        of: find.text('Project details in the Explorer'),
        matching: find.byType(SettingsSwitchRow),
      ),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).explorerProjectDetails,
      isFalse,
    );
    expect(
      SettingsRepository(server.store).load().explorerProjectDetails,
      isFalse,
    );
  });

  testWidgets('lists each surface checked, and a tap hides and shows it', (
    tester,
  ) async {
    final container = await pump(
      tester,
      const Scaffold(
        body: SingleChildScrollView(child: SidePanelItemsSection()),
      ),
    );
    expect(find.text(SettingsAnchor.sidePanel.heading), findsOneWidget);
    for (final surface in SidePanelSurface.offered(
      debugMode: container.read(settingsControllerProvider).debugMode,
    )) {
      expect(checked(tester, surface.label), isTrue, reason: surface.label);
    }

    await tester.tap(row('Media'));
    await tester.pumpAndSettle();
    expect(checked(tester, 'Media'), isFalse);
    expect(stored(), ['media']);
    expect(container.read(hiddenSidePanelSurfacesProvider), {
      SidePanelSurface.media,
    });

    // The checkbox itself does the same as the row.
    await tester.tap(
      find.descendant(of: row('Media'), matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(stored(), isEmpty);
  });

  testWidgets('Show all is offered only while something is hidden', (
    tester,
  ) async {
    final container = await pump(
      tester,
      const Scaffold(
        body: SingleChildScrollView(child: SidePanelItemsSection()),
      ),
    );
    TextButton showAll() =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Show all'));
    expect(showAll().onPressed, isNull);

    final settings = container.read(settingsControllerProvider.notifier);
    settings.setSidePanelSurfaceHidden('plan', hidden: true);
    settings.setSidePanelSurfaceHidden('todos', hidden: true);
    await tester.pumpAndSettle();
    expect(checked(tester, 'Plan'), isFalse);

    await tester.tap(find.widgetWithText(TextButton, 'Show all'));
    await tester.pumpAndSettle();
    expect(stored(), isEmpty);
    expect(checked(tester, 'Plan'), isTrue);
  });

  testWidgets('search finds it by the words people use for it', (tester) async {
    const size = Size(1280, 560);
    await pump(tester, const SettingsScreen(), size: size);
    for (final query in ['activity bar', 'rail', 'hide', 'side panel']) {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(SettingsSearchHitRow, 'Side panel items'),
        findsOneWidget,
        reason: query,
      );
    }
    await tester.tap(
      find.widgetWithText(SettingsSearchHitRow, 'Side panel items'),
    );
    await tester.pumpAndSettle();
    expect(find.text(SettingsAnchor.sidePanel.heading), findsOneWidget);
  });

  testWidgets('a deep link scrolls to the section', (tester) async {
    const size = Size(1280, 560);
    await pump(
      tester,
      const SettingsScreen(initialAnchor: SettingsAnchor.sidePanel),
      size: size,
    );
    final heading = find.text(SettingsAnchor.sidePanel.heading);
    expect(heading, findsOneWidget);
    final top = tester.getTopLeft(heading).dy;
    expect(top >= 0 && top < size.height, isTrue, reason: 'at $top');
  });

  testWidgets('survives the window matrix', (tester) async {
    final container = await prepared();
    container
        .read(settingsControllerProvider.notifier)
        .setSidePanelSurfaceHidden('media', hidden: true);
    await expectSurvivesWindowMatrix(
      tester,
      // From the page's top, as every page is: the matrix walks focus from the
      // first stop, and a deep link would start it scrolled past the theme row.
      build: () => app(
        container,
        const SettingsScreen(initialSection: SettingsSectionId.appearance),
      ),
      warmUp: (tester) async {
        expect(find.byType(SidePanelSurfaceCheckRow), findsWidgets);
      },
      because:
          'the checklist is seventeen rows on a page that opens at the '
          'minimum window and with large text',
    );
  });
}
