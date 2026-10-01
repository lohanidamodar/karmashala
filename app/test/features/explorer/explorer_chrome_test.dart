import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_scope_bar.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_tree_rows.dart';
import 'package:karmashala/src/features/explorer/presentation/sidebar_chrome.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What the Explorer's top-left costs, and what each glyph in it means.**
///
/// The owner's report was two findings in one sentence — *"it looks like too
/// many things happening and on the left we have same icon repeated 3 times"* —
/// and both are measurable, so both are pinned here rather than eyeballed.
///
/// **The repeated icon was one glyph standing for three different things.**
/// `AppIcons.treeStructure` marked the Explorer *surface* (its title-bar toggle
/// and its pane header), a *project*, and the workspace *scope*; the first
/// three of those stack ~30px apart in the same 16px column at the top-left, so
/// the corner drew the same mark three times and none of the three copies said
/// which it was. The vocabulary is now [AppIcons.treeStructure] for the surface
/// alone, [AppIcons.folders] for every project, [AppIcons.stack] for a context
/// and [AppIcons.minusCircle] for the projects filed under nothing — and the
/// closed scope bar wears whichever of the last three is selected, so it agrees
/// with the menu row that set it.
///
/// **The chrome is measured because it is taken from the list.** Two rows sit
/// above the tree — the area header and the search field. The filters are one
/// more, drawn only while there is something to filter by: the groups as
/// quiet tabs from the left, and with a second machine its menu at the same
/// row's end. They were two rows of outlined pills — the machines centred, the
/// groups under them, "All" twice — and the owner's screenshot of that said
/// they did not play with the rest of the chrome; one row is ratcheted here.
void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
  });

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(
      overrides: [
        await server.override(),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // A project row asks git what its checkout has changed. A widget test
        // must never spawn one.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// The Explorer in a column [paneWidth] wide, inside a window of [window].
  Future<void> pumpPanel(
    WidgetTester tester, {
    required Size window,
    required double paneWidth,
    ProviderContainer? scope,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope ?? await container(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: paneWidth, child: const ExplorerPanel()),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double heightOf(WidgetTester tester, Finder finder) =>
      tester.getSize(finder).height;

  /// The whole search row, padding included: the block the list gives up.
  Finder searchBlock() => find
      .ancestor(of: find.byType(TextField), matching: find.byType(Padding))
      .first;

  group('the chrome above the list', () {
    // §6's proof obligation: the two sizes, plus the smallest window the app
    // supports, where the same chrome is the largest share of the column.
    for (final cell in const [
      ('desktop 1440x900', Size(1440, 900), 304.0),
      ('phone 390x844', Size(390, 844), 390.0),
      ('minimum window 720x560', Size(720, 560), 240.0),
    ]) {
      final (label, window, paneWidth) = cell;
      testWidgets('is two rows — the area header and the search field — at '
          '$label', (tester) async {
        await pumpPanel(tester, window: window, paneWidth: paneWidth);

        expect(
          heightOf(tester, find.byType(SidebarAreaHeader)),
          Sidebar.headerHeight,
        );
        expect(heightOf(tester, searchBlock()), ExplorerSearchField.height);
        expect(
          heightOf(tester, find.byType(ExplorerScopeBar)),
          ExplorerSearchField.height,
          reason:
              'with no contexts and one machine there is nothing to filter '
              'by, and no row for it',
        );
      });
    }

    testWidgets('with no contexts and one machine the filter row takes '
        'nothing', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      expect(find.byType(ExplorerFilterRow), findsOneWidget);
      expect(heightOf(tester, find.byType(ExplorerFilterRow)), 0);
    });

    testWidgets('the groups are one more row: its gap and a tab', (
      tester,
    ) async {
      final c = await container();
      await createContext(c, 'Game dev');
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );
      expect(
        heightOf(tester, find.byType(ExplorerFilterRow)),
        Sidebar.headerGap + SidebarFilterTab.height,
      );
    });

    testWidgets('a second machine is that same row — its menu at the end of '
        'the groups, never a row of its own, at any pane width', (
      tester,
    ) async {
      server.environmentRows.upsert(sshEnvFixture());
      final c = await container();
      await createContext(c, 'Game dev');
      for (final paneWidth in [520.0, 304.0, 240.0]) {
        await pumpPanel(
          tester,
          window: const Size(1440, 900),
          paneWidth: paneWidth,
          scope: c,
        );
        expect(tester.takeException(), isNull);
        final menu = find.byType(ExplorerEnvironmentSwitcher);
        expect(menu, findsOneWidget);
        expect(
          heightOf(tester, find.byType(ExplorerScopeBar)),
          ExplorerSearchField.height +
              Sidebar.headerGap +
              SidebarFilterTab.height,
          reason: 'at $paneWidth: the field and one filter row, no more',
        );
        expect(
          tester.getTopLeft(menu).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TextField)).dy),
        );
        expect(
          tester.getSize(find.byType(TextField)).width,
          paneWidth - Sidebar.fillEdge * 2,
          reason: 'the field keeps its whole row',
        );
      }
    });

    testWidgets('leaves the list the rest of the column', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      // Nothing else may quietly take a slice: chrome plus list is the column.
      final list = heightOf(tester, find.byType(ListView));
      final chrome =
          heightOf(tester, find.byType(SidebarAreaHeader)) +
          heightOf(tester, find.byType(ExplorerScopeBar));
      expect(chrome + list, 900);
    });

    // The Agents entry the owner approved on 2026-09-21 left with the
    // mockup's sidebar (46185a97c): the Sessions area is every session by
    // what it needs, one click away on the strip.
    testWidgets('there is no Agents entry row above the list', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      expect(find.byType(AgentsEntryRow), findsNothing);
    });
  });

  group('the area name', () {
    /// Whether the header's title is being ellipsised at [paneWidth].
    Future<bool> clipsAt(WidgetTester tester, double paneWidth) async {
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: paneWidth,
      );
      return tester
          .renderObject<RenderParagraph>(
            find.descendant(
              of: find.byType(SidebarAreaHeader),
              matching: find.text('Projects'),
            ),
          )
          .didExceedMaxLines;
    }

    testWidgets('fits at the default pane width', (tester) async {
      expect(await clipsAt(tester, 304), isFalse);
    });

    testWidgets('fits at the pane\'s smallest width', (tester) async {
      expect(await clipsAt(tester, 240), isFalse);
    });
  });

  group('the glyph vocabulary', () {
    testWidgets('the area header does not repeat the surface mark', (
      tester,
    ) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      final inHeader = find.descendant(
        of: find.byType(SidebarAreaHeader),
        matching: find.byType(Icon),
      );
      for (final icon in tester.widgetList<Icon>(inHeader)) {
        expect(
          icon.icon,
          isNot(AppIcons.treeStructure),
          reason: 'the title-bar toggle draws it above, same column',
        );
      }
    });

    /// Every glyph [within] is drawing, in order.
    List<IconData> glyphs(WidgetTester tester, Finder within) => [
      for (final icon in tester.widgetList<Icon>(
        find.descendant(of: within, matching: find.byType(Icon)),
      ))
        if (icon.icon case final IconData data) data,
    ];

    testWidgets('the machine menu wears the mark of what is in scope, then '
        'its caret', (tester) async {
      server.environmentRows.upsert(sshEnvFixture());
      final c = await container();
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );
      final menu = find.byType(ExplorerEnvironmentSwitcher);
      expect(glyphs(tester, menu), [
        AppIcons.stack,
        AppIcons.caretDown,
      ], reason: 'every machine together is a stack of them');

      final settings = c.read(settingsControllerProvider.notifier);
      settings.setExplorerEnvironmentScope('windows');
      await tester.pumpAndSettle();
      expect(glyphs(tester, menu), [
        AppIcons.terminal,
        AppIcons.caretDown,
      ], reason: 'a local machine is a terminal');

      settings.setExplorerEnvironmentScope('ssh:h1');
      await tester.pumpAndSettle();
      expect(glyphs(tester, menu), [
        AppIcons.globe,
        AppIcons.caretDown,
      ], reason: 'a box is a globe');
    });

    testWidgets('a context is a label over its projects, with no glyph at '
        'rest', (tester) async {
      final c = await container();
      final games = await createContext(c, 'Game dev');
      await c
          .read(workspacesControllerProvider.notifier)
          .assign('p1', games.id);
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );

      expect(find.text('GAME DEV'), findsOneWidget);
      expect(
        glyphs(tester, find.byType(ExplorerContextHeader).first),
        isEmpty,
        reason:
            'a header is words; its caret comes with the pointer or the '
            'fold, and the stack is in the menus',
      );
    });
  });
}
