import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/agents_lens.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_scope_bar.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_tree_rows.dart';
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
/// above the tree — the pane header and the search field, which a fourth
/// machine's menu shares rather than adding to. Two or three machines are a
/// strip on a row of its own under the field — it shared the field's row at
/// first and the owner's screenshot of that was a crush — costing exactly
/// [Chrome.control] and a gap. The context chips are one more, drawn only
/// while there are contexts; they came back on 2026-09-17 in exchange for
/// three levels of the tree (SETTLED, "The Explorer is two levels"), and they
/// are ratcheted here like the others.
void main() {
  late AppDatabase db;
  late FakeDataServer server;

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
  });
  tearDown(() => db.close());

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
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
    // supports, where the same 109px is five times the share of the column.
    for (final cell in const [
      ('desktop 1440x900', Size(1440, 900), 304.0),
      ('phone 390x844', Size(390, 844), 390.0),
      ('minimum window 720x560', Size(720, 560), 240.0),
    ]) {
      final (label, window, paneWidth) = cell;
      testWidgets('is two rows and 83px at $label', (tester) async {
        await pumpPanel(tester, window: window, paneWidth: paneWidth);

        // The header is its row plus the hairline it owns.
        expect(heightOf(tester, find.byType(PaneHeader)), Chrome.tabStrip + 1);

        final chrome =
            heightOf(tester, find.byType(PaneHeader)) +
            heightOf(tester, searchBlock());
        expect(
          chrome,
          lessThanOrEqualTo(83),
          reason:
              'the rows above the tree cost a project row already — a third '
              'row, or a taller one, has to be argued for',
        );
      });
    }

    testWidgets('with no contexts the chips take nothing', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      expect(find.byType(ExplorerContextChips), findsOneWidget);
      expect(heightOf(tester, find.byType(ExplorerContextChips)), 0);
    });

    testWidgets('the context chips are one more row, and 27px', (tester) async {
      final c = await container();
      await createContext(c, 'Game dev');
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );
      expect(
        heightOf(tester, find.byType(ExplorerContextChips)),
        lessThanOrEqualTo(27),
      );
    });

    testWidgets('a second machine adds its strip on a row of its own under '
        'the search field — never beside it, however wide the pane — and '
        'the row costs one control and its gap', (tester) async {
      ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
      // 520 is where `All · Windows · build-box` once fit beside the field
      // whole; it is a row of its own there too now.
      for (final paneWidth in [520.0, 304.0, 240.0]) {
        await pumpPanel(
          tester,
          window: const Size(1440, 900),
          paneWidth: paneWidth,
        );
        final strip = find.byType(ExplorerEnvironmentStrip);
        expect(strip, findsOneWidget);
        expect(
          heightOf(tester, find.byType(ExplorerScopeBar)),
          heightOf(tester, searchBlock()) + Chrome.control + Insets.xs,
          reason: 'at $paneWidth: one row more, and only the strip and its gap',
        );
        expect(heightOf(tester, strip), Chrome.control);
        expect(
          tester.getTopLeft(strip).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TextField)).dy),
        );
        expect(
          tester.getSize(strip).width,
          paneWidth - Insets.xs * 2,
          reason: 'it spans the column the field and the rows share',
        );
        expect(
          tester.getSize(find.byType(TextField)).width,
          paneWidth - Insets.xs * 2,
          reason: 'the field keeps its whole row',
        );
      }
      // Three containers were mounted in turn; the last is taken down here,
      // where its providers' dispose tick can run, not in the teardown.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a fourth machine folds the strip into a menu on the search '
        'row', (tester) async {
      ExecutionEnvironmentDao(db)
        ..upsert(sshEnvFixture())
        ..upsert(wslEnv())
        ..upsert(wslEnv(id: 'wsl:arch', distro: 'archlinux'));
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      expect(find.byType(ExplorerEnvironmentStrip), findsNothing);
      expect(find.byType(ExplorerEnvironmentSwitcher), findsOneWidget);
      expect(
        heightOf(tester, find.byType(ExplorerScopeBar)),
        heightOf(tester, searchBlock()),
      );
    });

    testWidgets('leaves the list the rest of the column', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      // Nothing else may quietly take a slice: chrome plus list is the column.
      final list = heightOf(tester, find.byType(ListView));
      final chrome =
          heightOf(tester, find.byType(PaneHeader)) +
          heightOf(tester, find.byType(AgentsEntryRow)) +
          heightOf(tester, searchBlock());
      expect(chrome + list, 900);
    });

    // The third row, argued for: the owner approved a global Agents entry
    // (2026-09-21) because "who is blocked on me" is the first question across
    // forty projects. It is held to one row, and its count costs no width
    // until something is waiting.
    testWidgets('the Agents entry is one row, and 27px', (tester) async {
      await pumpPanel(tester, window: const Size(1440, 900), paneWidth: 304);
      expect(
        heightOf(tester, find.byType(AgentsEntryRow)),
        lessThanOrEqualTo(Chrome.row + 1),
      );
      expect(find.byKey(const ValueKey('agents-needs-you-pill')), findsNothing);
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

    /// Every glyph [within] is drawing, in order.
    List<IconData> glyphs(WidgetTester tester, Finder within) => [
      for (final icon in tester.widgetList<Icon>(
        find.descendant(of: within, matching: find.byType(Icon)),
      ))
        if (icon.icon case final IconData data) data,
    ];

    testWidgets('every segment wears the mark of what it is, and the one in '
        'scope is the one marked', (tester) async {
      ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
      final c = await container();
      // Wide enough that `build-box` — nine squares in the test font — fits
      // beside a glyph; narrower, the strip rightly drops the glyphs for
      // whole names (explorer_scope_test pins where).
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 520,
        scope: c,
      );
      expect(
        glyphs(tester, find.byType(ExplorerEnvironmentStrip)),
        [AppIcons.stack, AppIcons.terminal, AppIcons.globe],
        reason:
            'every machine together is a stack of them; a local one is a '
            'terminal, a box a globe',
      );
      String chosen() {
        final segments = find.bySemanticsLabel(RegExp('^Environment: '));
        return [
              for (var i = 0; i < segments.evaluate().length; i++)
                tester.getSemantics(segments.at(i)),
            ]
            .singleWhere(
              (node) => node.flagsCollection.isSelected == Tristate.isTrue,
            )
            .label;
      }

      expect(chosen(), 'Environment: All environments');

      c
          .read(settingsControllerProvider.notifier)
          .setExplorerEnvironmentScope('windows');
      await tester.pumpAndSettle();
      expect(chosen(), 'Environment: Windows');
    });

    testWidgets('as a menu, the machine in scope wears the mark of what it '
        'is', (tester) async {
      ExecutionEnvironmentDao(db)
        ..upsert(sshEnvFixture())
        ..upsert(wslEnv())
        ..upsert(wslEnv(id: 'wsl:arch', distro: 'archlinux'));
      final c = await container();
      await pumpPanel(
        tester,
        window: const Size(1440, 900),
        paneWidth: 304,
        scope: c,
      );
      expect(
        glyphs(tester, find.byType(ExplorerEnvironmentSwitcher)),
        contains(AppIcons.stack),
        reason: 'every machine together is a stack of them',
      );

      c
          .read(settingsControllerProvider.notifier)
          .setExplorerEnvironmentScope('windows');
      await tester.pumpAndSettle();
      expect(
        glyphs(tester, find.byType(ExplorerEnvironmentSwitcher)),
        contains(AppIcons.terminal),
        reason: 'this machine is a local one, and the switcher says so',
      );
    });

    testWidgets('a context is a label over its projects, with no glyph', (
      tester,
    ) async {
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
      expect(glyphs(tester, find.byType(ExplorerContextHeader).first), [
        AppIcons.caretDown,
      ], reason: 'a header is words and a caret; the stack is in the menus');
    });
  });
}
