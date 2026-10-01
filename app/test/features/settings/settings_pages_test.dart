import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/editor/application/code_editor_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_page_body.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/settings/presentation/settings_tab_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../../support/fake_data_server.dart';
import 'package:agent_cli/process.dart';

/// The settings screen as the catalogue draws it: every page and section,
/// search that lands on a section, deep links that do, and the narrow layout.
void main() {
  Future<ProviderContainer> prepared() async {
    final server = FakeDataServer()
      ..environmentRows.upsert(localHostEnvironment(testTime));
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        // The Terminal page reads the session host's status, and the one running
        // on this machine is not the test's to dial.
        localHostSessionAccessProvider.overrideWithValue(null),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // Theme discovery and app detection read the real machine.
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

  /// Whether [finder]'s top edge is inside the window's height.
  bool onScreen(WidgetTester tester, Finder finder, Size size) {
    final top = tester.getTopLeft(finder).dy;
    return top >= 0 && top < size.height;
  }

  group('every page', () {
    for (final page in SettingsSectionId.values) {
      testWidgets('${page.label} draws each of its sections, headed', (
        tester,
      ) async {
        await pump(tester, SettingsScreen(initialSection: page));
        expect(tester.takeException(), isNull);
        expect(find.byType(SettingsPageBody), findsOneWidget);
        expect(find.text(page.description), findsOneWidget);
        for (final anchor in page.anchors) {
          expect(
            find.byWidgetPredicate(
              (w) => w is SettingsAnchorTarget && w.anchor == anchor,
            ),
            findsOneWidget,
            reason: '${anchor.title} is not on ${page.label}',
          );
          if (_drawsNothingWhenEmpty.contains(anchor)) continue;
          expect(
            find.descendant(
              of: find.byWidgetPredicate(
                (w) => w is SettingsAnchorTarget && w.anchor == anchor,
              ),
              matching: find.text(anchor.heading),
            ),
            findsOneWidget,
            reason: 'the catalogue calls it "${anchor.heading}"',
          );
        }
      });
    }
  });

  group('search', () {
    testWidgets('finds an option by its label and opens its section', (
      tester,
    ) async {
      const size = Size(1280, 560);
      await pump(tester, const SettingsScreen(), size: size);

      await tester.enterText(find.byType(TextField).first, 'session host');
      await tester.pumpAndSettle();

      // The rail narrows to the page and lists the setting under it.
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);
      final hit = find.widgetWithText(
        SettingsSearchHitRow,
        'Run local terminals in the session host',
      );
      expect(hit, findsOneWidget);

      await tester.tap(hit);
      await tester.pumpAndSettle();

      final heading = find.text(SettingsAnchor.terminalAdvanced.heading);
      expect(heading, findsOneWidget);
      expect(
        onScreen(tester, heading, size),
        isTrue,
        reason: 'the last section of a long page is scrolled to',
      );
    });

    testWidgets('finds an option by its description', (tester) async {
      await pump(tester, const SettingsScreen());

      await tester.enterText(find.byType(TextField).first, 'dot-files');
      await tester.pumpAndSettle();
      final hit = find.widgetWithText(
        SettingsSearchHitRow,
        'Show hidden files',
      );
      expect(hit, findsOneWidget);

      await tester.tap(hit);
      await tester.pumpAndSettle();
      expect(find.text('FILE BROWSING'), findsOneWidget);
    });

    testWidgets('says so when nothing matches', (tester) async {
      await pump(tester, const SettingsScreen());
      await tester.enterText(find.byType(TextField).first, 'zzqxv');
      await tester.pumpAndSettle();
      expect(find.text('Nothing matches.'), findsOneWidget);
      expect(find.byType(SettingsNavGroupHeader), findsNothing);
    });
  });

  group('deep links', () {
    testWidgets('a section link scrolls its section into view', (tester) async {
      const size = Size(1280, 560);
      await pump(
        tester,
        const SettingsScreen(initialAnchor: SettingsAnchor.terminalAdvanced),
        size: size,
      );
      final heading = find.text(SettingsAnchor.terminalAdvanced.heading);
      expect(find.text('DEFAULT TERMINAL'), findsOneWidget);
      expect(onScreen(tester, heading, size), isTrue);
    });

    testWidgets('a page link without a section lands at its top', (
      tester,
    ) async {
      const size = Size(1280, 560);
      await pump(
        tester,
        const SettingsScreen(initialSection: SettingsSectionId.terminal),
        size: size,
      );
      final heading = find.text(SettingsAnchor.terminalAdvanced.heading);
      expect(
        onScreen(tester, heading, size),
        isFalse,
        reason:
            'the control for the scroll test above: unscrolled, the '
            'section is below the fold',
      );
    });

    testWidgets('the tab follows a link that arrives while it is open', (
      tester,
    ) async {
      const size = Size(1280, 560);
      final container = await pump(tester, const SettingsTabView(), size: size);
      expect(find.text('STARTUP & WINDOW'), findsOneWidget);

      container
          .read(settingsTabSectionProvider.notifier)
          .reveal(SettingsTarget.anchor(SettingsAnchor.knownHosts));
      await tester.pumpAndSettle();

      final heading = find.text(SettingsAnchor.knownHosts.heading);
      expect(heading, findsOneWidget);
      expect(onScreen(tester, heading, size), isTrue);
    });
  });

  group('narrow windows', () {
    // Spec §6 (6bb8a9813): under the compact width a page shows at once,
    // under a sticky picker; its Search opens the list, grouped.
    Finder picked(String page) => find.descendant(
      of: find.byType(SettingsCategoryPicker),
      matching: find.text(page),
    );

    // Both under ShellWidth.compactBelow; at 720 the list stands beside the
    // page, as the desktop's does.
    for (final width in const [390.0, 560.0]) {
      testWidgets('at ${width.round()}px the page sits under the picker, and '
          'Search is the list, grouped', (tester) async {
        await pump(tester, const SettingsScreen(), size: Size(width, 844));

        expect(find.byType(SettingsCategoryPicker), findsOneWidget);
        expect(find.byType(SettingsPageBody), findsOneWidget);
        expect(find.byType(SettingsNav), findsNothing);

        await tester.tap(find.byTooltip('Search settings'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsNav), findsOneWidget);
        expect(find.byType(SettingsPageBody), findsNothing);
        expect(
          find.byType(SettingsNavGroupHeader),
          findsNWidgets(SettingsGroup.values.length),
        );

        await tester.tap(find.text('Projects and files'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsNav), findsNothing);
        expect(picked('Projects and files'), findsOneWidget);
        expect(find.text('IN-APP EDITOR'), findsOneWidget);
      });
    }

    testWidgets('a search hit opens its page full width', (tester) async {
      await pump(tester, const SettingsScreen(), size: const Size(390, 844));
      await tester.tap(find.byTooltip('Search settings'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'quota');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SettingsSearchHitRow, 'Usage & limits'),
      );
      await tester.pumpAndSettle();
      expect(picked('Agents and accounts'), findsOneWidget);
      expect(find.text('USAGE & LIMITS'), findsOneWidget);
    });
  });

  group('window matrix', () {
    for (final page in SettingsSectionId.values) {
      testWidgets(page.label, (tester) async {
        final container = await prepared();
        await expectSurvivesWindowMatrix(
          tester,
          build: () => app(container, SettingsScreen(initialSection: page)),
          because:
              'every settings page opens at the minimum window, at '
              'desktop size and with large text',
        );
      });
    }
  });
}

/// Sections that draw nothing, heading included, when there is nothing to
/// show in the empty database these tests use: no agent is installed.
const _drawsNothingWhenEmpty = {SettingsAnchor.executables};
