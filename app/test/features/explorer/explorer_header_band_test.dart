import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/environment_rows.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_scope_bar.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:karmashala/src/features/workspaces/presentation/context_color_dialog.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspaces_dialog.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **A context is told from a project by more than its capitals.** Every
/// group header rests on a tinted band with a hairline under it and a gap
/// above it between groups; a context the owner has coloured wears the dot in
/// its header's glyph column and on its chip, and the colour is kept.
void main() {
  late AppDatabase db;

  void seed() {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    for (final (id, name) in [('w1', 'Client work'), ('w2', 'Game dev')]) {
      WorkspaceDao(
        db,
      ).insert(Workspace(id: id, name: name, createdAt: testTime));
    }
    final projects = ProjectDao(db);
    for (var i = 0; i < 6; i++) {
      projects.insert(
        project(
          id: 'c$i',
          name: 'client-$i',
          path: 'C:\\src\\client-$i',
          workspaceId: 'w1',
        ),
      );
    }
    projects
      ..insert(
        project(
          id: 'p2',
          name: 'roguelike',
          path: r'C:\src\rogue',
          workspaceId: 'w2',
        ),
      )
      ..insert(project(id: 'p3', name: 'scratch', path: r'C:\src\scratch'));
    AgentInstallationDao(db).insert(agentInstallation());
  }

  setUp(() {
    db = AppDatabase.memory();
    seed();
  });
  tearDown(() => db.close());

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(760, 900),
    ThemeData? theme,
    ProviderContainer? container,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final scope = container ?? newContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: (theme ?? AppTheme.light()).copyWith(
            platform: TargetPlatform.windows,
          ),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scope;
  }

  ColorScheme schemeOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(ExplorerPanel))).colorScheme;

  Finder header(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(ExplorerGroupHeader),
  );

  /// The one box a row is filled by: the decoration nearest the row's edge.
  BoxDecoration fillOf(WidgetTester tester, Finder row) => tester
      .widgetList<DecoratedBox>(
        find.descendant(of: row, matching: find.byType(DecoratedBox)),
      )
      .map((box) => box.decoration)
      .whereType<BoxDecoration>()
      .first;

  Finder bandBox(WidgetTester tester, Finder row) =>
      find.descendant(of: row, matching: find.byType(DecoratedBox)).first;

  Finder dotIn(Finder within) =>
      find.descendant(of: within, matching: find.byType(ContextHueDot));

  Finder chip(String label) => find.descendant(
    of: find.byType(ExplorerContextChips),
    matching: find.text(label),
  );

  Future<void> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
  }

  group('the band', () {
    for (final (name, theme) in [
      ('light', AppTheme.light()),
      ('dark', AppTheme.dark()),
    ]) {
      testWidgets('is under every header in $name — a context, No context, '
          'Terminals — one step under the pane, with a hairline beneath, and '
          'under no other row', (tester) async {
        await pump(tester, theme: theme);
        final scheme = schemeOf(tester);

        for (final label in [
          'CLIENT WORK',
          'GAME DEV',
          'NO CONTEXT',
          'TERMINALS',
        ]) {
          final fill = fillOf(tester, header(label));
          expect(
            fill.color,
            ExplorerRow.bandColor(scheme),
            reason: '$label rests on the band',
          );
          expect(fill.color, scheme.surfaceContainerLow);
          expect(fill.borderRadius, isNull, reason: 'a band has square ends');
          final border = fill.border! as Border;
          expect(border.bottom.color, scheme.outlineVariant);
          expect(border.bottom.width, ExplorerRow.bandHairline);
          expect(border.top, BorderSide.none);
          expect(
            tester.getSize(bandBox(tester, header(label))).width,
            760,
            reason: '$label\'s band runs to the pane\'s edges',
          );
        }
        for (final row in find.byType(ExplorerProjectRow).evaluate()) {
          final fill = fillOf(tester, find.byWidget(row.widget));
          expect(fill.color, isNull, reason: 'a project rests transparent');
          expect(fill.border, isNull);
        }
      });
    }

    testWidgets('keeps the columns: a header\'s label starts where a '
        'project\'s name does, though its band runs wider than the row', (
      tester,
    ) async {
      await pump(tester);
      final label = tester.getTopLeft(find.text('CLIENT WORK')).dx;
      final name = tester.getTopLeft(find.text('client-0')).dx;
      expect(label, name);
      expect(
        tester.getTopLeft(bandBox(tester, header('CLIENT WORK'))).dx,
        0,
        reason: 'the band starts at the pane\'s edge',
      );
      expect(
        tester
            .getTopLeft(
              find
                  .descendant(
                    of: find.ancestor(
                      of: find.text('client-0'),
                      matching: find.byType(ExplorerProjectRow),
                    ),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            )
            .dx,
        ExplorerRow.inset,
        reason: 'a project\'s fill keeps its inset',
      );
    });

    testWidgets('has a gap above it between groups and none before the '
        'first', (tester) async {
      await pump(tester);
      double top(Finder f) => tester.getTopLeft(f).dy;
      double bottom(Finder f) => tester.getBottomLeft(f).dy;

      // The first header: its band starts where its row does.
      expect(
        top(bandBox(tester, header('CLIENT WORK'))),
        top(header('CLIENT WORK')),
      );
      // The next: the row above ends, one hairline of list gap, then the
      // band's own gap, then the band.
      final above = find.ancestor(
        of: find.text('client-5'),
        matching: find.byType(ExplorerProjectRow),
      );
      expect(
        top(bandBox(tester, header('GAME DEV'))) - bottom(above),
        ExplorerRow.bandGap,
      );
      expect(
        top(bandBox(tester, header('GAME DEV'))) - top(header('GAME DEV')),
        ExplorerRow.bandGap,
      );
    });

    testWidgets('is on the pinned copy too — the same tone and hairline, and '
        'no gap above, so a header pinning changes nothing about it', (
      tester,
    ) async {
      // Short, so the list has something to scroll.
      await pump(tester, size: const Size(760, 260));
      final scheme = schemeOf(tester);
      expect(find.byType(ExplorerPinnedHeader), findsOneWidget);
      // Scroll the client group's projects under the top edge.
      await tester.drag(find.byType(ListView), const Offset(0, -60));
      await tester.pumpAndSettle();

      final pinned = find.descendant(
        of: find.byType(ExplorerPinnedHeader),
        matching: find.byType(ExplorerGroupHeader),
      );
      expect(pinned, findsOneWidget);
      expect(
        find.descendant(of: pinned, matching: find.text('CLIENT WORK')),
        findsOneWidget,
      );
      final fill = fillOf(tester, pinned);
      expect(fill.color, ExplorerRow.bandColor(scheme));
      expect((fill.border! as Border).bottom.color, scheme.outlineVariant);
      expect(
        tester.getTopLeft(bandBox(tester, pinned)).dy,
        tester.getTopLeft(find.byType(ExplorerPinnedHeader)).dy,
        reason: 'the pinned copy sits at the edge with no gap',
      );
      // Nothing but the row's own decoration: the wrapper draws no second
      // hairline of its own.
      final wrapper = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(ExplorerPinnedHeader),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((wrapper.decoration as BoxDecoration).border, isNull);
    });

    testWidgets('takes the hover wash over it rather than in its place', (
      tester,
    ) async {
      await pump(tester);
      final scheme = schemeOf(tester);
      await hover(tester, find.text('GAME DEV'));
      expect(
        fillOf(tester, header('GAME DEV')).color,
        Color.alphaBlend(
          StateLayers.hover(scheme),
          ExplorerRow.bandColor(scheme),
        ),
      );
    });
  });

  group('the colour', () {
    testWidgets('is none by default: no dot on any header or chip', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(ContextHueDot), findsNothing);
      expect(
        WorkspaceDao(db).getById('w2')!.color,
        isNull,
        reason: 'nothing is stored until something is picked',
      );
    });

    testWidgets('picked from the header\'s menu, is the dot in the header\'s '
        'glyph column and before the chip\'s label, in the theme\'s variant, '
        'and is kept', (tester) async {
      var container = await pump(tester);
      await hover(tester, find.text('GAME DEV'));
      await tester.tap(
        find.descendant(
          of: header('GAME DEV'),
          matching: find.byTooltip('Context actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colour…'));
      await tester.pumpAndSettle();
      expect(find.byType(ContextColorDialog), findsOneWidget);
      // The swatch itself: the pointer left from the hover above can rest on
      // it, and its tooltip then says "None" as well.
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'None',
        ),
        findsOneWidget,
      );
      for (final hue in ContextHue.values) {
        expect(find.byTooltip(hue.label), findsOneWidget);
      }

      await tester.tap(find.byTooltip('Teal'));
      await tester.pumpAndSettle();
      expect(find.byType(ContextColorDialog), findsNothing);

      expect(WorkspaceDao(db).getById('w2')!.color, 'teal');
      expect(
        container
            .read(workspacesControllerProvider)
            .firstWhere((w) => w.id == 'w2')
            .color,
        'teal',
      );
      expect(dotIn(header('GAME DEV')), findsOneWidget);
      expect(dotIn(header('CLIENT WORK')), findsNothing);
      final headerDot = tester.widget<ContextHueDot>(dotIn(header('GAME DEV')));
      expect(headerDot.hue, ContextHue.teal);
      expect(headerDot.size, ContextHueDot.headerSize);
      expect(
        find.bySemanticsLabel(RegExp('Teal context')),
        findsWidgets,
        reason: 'said to a screen reader, merged into the row',
      );

      // In the glyph column: centred where a project's folder glyph is.
      final folder = tester.getCenter(
        find.descendant(
          of: find.ancestor(
            of: find.text('roguelike'),
            matching: find.byType(ExplorerProjectRow),
          ),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Icon &&
                (w.icon == AppIcons.folder || w.icon == AppIcons.folderOpen),
          ),
        ),
      );
      expect(
        tester.getCenter(dotIn(header('GAME DEV'))).dx,
        moreOrLessEquals(folder.dx, epsilon: 0.5),
      );

      // On the chip, before the label, and still when the chip is in force.
      final chipRow = find
          .ancestor(of: chip('Game dev'), matching: find.byType(Row))
          .first;
      final chipDot = tester.widget<ContextHueDot>(dotIn(chipRow));
      expect(chipDot.hue, ContextHue.teal);
      expect(chipDot.size, ContextHueDot.chipSize);
      expect(
        tester.getTopRight(dotIn(chipRow)).dx,
        lessThan(tester.getTopLeft(chip('Game dev')).dx),
      );
      await tester.tap(chip('Game dev'));
      await tester.pumpAndSettle();
      expect(dotIn(chipRow), findsOneWidget);

      // Kept: a fresh container reads the colour back, and the dark theme
      // paints the dark variant of it.
      container = await pump(tester, theme: AppTheme.dark());
      expect(dotIn(header('GAME DEV')), findsOneWidget);
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: dotIn(header('GAME DEV')),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect((box.decoration as BoxDecoration).color, ContextHue.teal.dark);
      // Two containers were mounted in turn; the second is taken down here,
      // where its providers' dispose tick can run, not in the teardown.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('is offered on the chip\'s right-click, and None takes it '
        'away again', (tester) async {
      final container = await pump(tester);
      container
          .read(workspacesControllerProvider.notifier)
          .setColor('w1', 'rose');
      await tester.pumpAndSettle();
      expect(dotIn(header('CLIENT WORK')), findsOneWidget);

      await tester.tap(chip('Client work'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colour…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('None'));
      await tester.pumpAndSettle();

      expect(find.byType(ContextHueDot), findsNothing);
      expect(WorkspaceDao(db).getById('w1')!.color, isNull);
    });

    testWidgets('is offered in Manage contexts, on the row\'s glyph', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(chip('Client work'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage contexts…'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspacesDialog), findsOneWidget);

      await tester.tap(find.byTooltip('Colour for Game dev'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Violet'));
      await tester.pumpAndSettle();

      expect(WorkspaceDao(db).getById('w2')!.color, 'violet');
      expect(
        find.descendant(
          of: find.byType(WorkspacesDialog),
          matching: find.byType(ContextHueDot),
        ),
        findsOneWidget,
        reason: 'the row wears it too',
      );
    });

    testWidgets('a name no build knows is no colour, not a crash', (
      tester,
    ) async {
      WorkspaceDao(db).updateColor('w1', 'chartreuse');
      await pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(ContextHueDot), findsNothing);
      expect(
        WorkspaceDao(db).getById('w1')!.color,
        'chartreuse',
        reason: 'kept as stored, for the build that named it',
      );
    });
  });
}
