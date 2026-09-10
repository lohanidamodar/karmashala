import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspace_scope_bar.dart';

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
/// **The chrome is measured because it is taken from the list.** Three rows sit
/// above the tree — the pane header, the scope bar, the search field — and at
/// the 720x560 minimum window they are 21% of the Explorer's column. That is
/// the ratchet: these numbers may fall, and a fourth row has to argue with a
/// failing test first.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
  });
  tearDown(() => db.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
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
        container: scope ?? container(),
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
    // supports, where the same 109px is five times the share of the column.
    for (final cell in const [
      ('desktop 1440x900', Size(1440, 900), 304.0),
      ('phone 390x844', Size(390, 844), 390.0),
      ('minimum window 720x560', Size(720, 560), 240.0),
    ]) {
      final (label, window, paneWidth) = cell;
      testWidgets('is three rows and 109px at $label', (tester) async {
        await pumpPanel(tester, window: window, paneWidth: paneWidth);

        // The header is its row plus the hairline it owns; the scope bar is one
        // dense list row, which is what makes it cost exactly one project.
        expect(heightOf(tester, find.byType(PaneHeader)), Chrome.tabStrip + 1);
        expect(heightOf(tester, find.byType(WorkspaceScopeBar)), Chrome.row);

        final chrome =
            heightOf(tester, find.byType(PaneHeader)) +
            heightOf(tester, find.byType(WorkspaceScopeBar)) +
            heightOf(tester, searchBlock());
        expect(
          chrome,
          lessThanOrEqualTo(109),
          reason:
              'the three rows above the tree cost two project rows '
              'already — a fourth row, or a taller one, has to be argued for',
        );
      });
    }

    testWidgets('leaves the list the rest of the column', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      // Nothing else may quietly take a slice: chrome plus list is the column.
      final list = heightOf(tester, find.byType(ListView));
      final chrome =
          heightOf(tester, find.byType(PaneHeader)) +
          heightOf(tester, find.byType(WorkspaceScopeBar)) +
          heightOf(tester, searchBlock());
      expect(chrome + list, 900);
    });
  });

  group('the pane name', () {
    /// Whether the header's title is being ellipsised at [paneWidth].
    Future<bool> clipsAt(WidgetTester tester, double paneWidth) async {
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: paneWidth,
      );
      return tester
          .renderObject<RenderParagraph>(find.text('EXPLORER'))
          .didExceedMaxLines;
    }

    // It used to clip below 280px — inside the range the pane is routinely
    // dragged to — because 150px of a ~300px row is five icon buttons and a
    // glyph took 21 more. The glyph is gone (see [PaneHeader.icon]) and the
    // word now survives to 259.
    testWidgets('fits at the default pane width', (tester) async {
      expect(await clipsAt(tester, 304), isFalse);
    });

    testWidgets('fits well below the default pane width', (tester) async {
      expect(await clipsAt(tester, 260), isFalse);
    });
  });

  group('the glyph vocabulary', () {
    /// The leading glyph the closed scope bar is wearing.
    IconData scopeGlyph(WidgetTester tester) => tester
        .widget<Icon>(
          find
              .descendant(
                of: find.byType(WorkspaceScopeBar),
                matching: find.byType(Icon),
              )
              .first,
        )
        .icon!;

    testWidgets('the pane header no longer repeats the surface mark', (
      tester,
    ) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      final inHeader = find.descendant(
        of: find.byType(PaneHeader),
        matching: find.byType(Icon),
      );
      for (final icon in tester.widgetList<Icon>(inHeader)) {
        expect(
          icon.icon,
          isNot(AppIcons.treeStructure),
          reason: 'the title-bar toggle draws it 30px above, same column',
        );
      }
    });

    testWidgets('every project is folders, never the surface mark', (
      tester,
    ) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      expect(scopeGlyph(tester), AppIcons.folders);
    });

    testWidgets('a context is a stack', (tester) async {
      final c = container();
      final games = c
          .read(workspacesControllerProvider.notifier)
          .create('Game dev');
      c
          .read(workspaceScopeProvider.notifier)
          .select(WorkspaceScope.of(games.id));
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );
      expect(scopeGlyph(tester), AppIcons.stack);
    });

    testWidgets('the projects filed under nothing keep the menu mark', (
      tester,
    ) async {
      final c = container();
      c.read(workspacesControllerProvider.notifier).create('Game dev');
      c.read(workspaceScopeProvider.notifier).select(WorkspaceScope.unassigned);
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );
      expect(scopeGlyph(tester), AppIcons.minusCircle);
    });
  });
}
