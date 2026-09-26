import 'dart:ui' show Tristate;

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_state.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_tree_rows.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/test_machine.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **The Explorer is a tree, and a tree is driven with the arrow keys.**
///
/// It had Tab, Enter, Space, Shift+F10, Escape and Cmd/Ctrl+A and nothing
/// else: reaching the twentieth project was forty Tabs, past every `+` and `⋮`
/// on the way. These are the keys every tree view has, over the rows in the
/// order the list draws them — built or not, since the list is lazy.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  void seed({int extra = 0}) {
    server.environmentRows.upsert(windowsEnv());
    for (final (id, name) in [('w1', 'Client work'), ('w2', 'Game dev')]) {
      server.workspaceRows.insert(
        Workspace(id: id, name: name, createdAt: testTime),
      );
    }
    final projects = server.projectRows;
    for (final (id, name, context) in [
      ('p1', 'alpha', 'w1'),
      ('p2', 'bravo', 'w1'),
      ('p3', 'charlie', 'w2'),
      ('p4', 'delta', null),
    ]) {
      projects.insert(
        project(
          id: id,
          name: name,
          path: 'C:\\src\\$name',
          workspaceId: context,
        ),
      );
    }
    // Filed in the first context, so they stand between `bravo` and the next
    // header: a list long enough to scroll.
    for (var i = 0; i < extra; i++) {
      final n = '$i'.padLeft(3, '0');
      projects.insert(
        project(
          id: 'x$n',
          name: 'extra-$n',
          path: 'C:\\src\\extra-$n',
          workspaceId: 'w1',
        ),
      );
    }
    server.repositoryRows.insert(
      repository(
        id: 'r1',
        projectId: 'p1',
        name: 'alpha',
        path: r'C:\src\alpha',
      ),
    );
    server.installationRows.insert(agentInstallation());
    for (final (i, title) in ['Fix login', 'Add tests'].indexed) {
      db.server.sessionRows.insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: title,
          useWorktree: false,
          status: SessionStatus.completed,
          // Newest first in the tree: `Fix login` is drawn above `Add tests`.
          createdAt: testTime.subtract(Duration(minutes: i)),
        ),
      );
    }
  }

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(460, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// The row holding keyboard focus, as the list labels it, or null.
  ExplorerTreeRow? focusedTreeRow() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    ExplorerTreeRow? row;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is! ExplorerTreeRow) return true;
      row = widget;
      return false;
    });
    return row;
  }

  String? focused() => switch (focusedTreeRow()?.node) {
    final ContextHeaderNode node => node.label.toUpperCase(),
    final TerminalsHeaderNode node => node.label.toUpperCase(),
    final SectionHeaderNode node => node.section.name,
    final ProjectNode node => node.project.name,
    final SessionRowNode node => node.session.title,
    final ImportedRowNode node => node.session.displayTitle,
    final TerminalRowNode node => node.terminal.label,
    HintNode() || null => null,
  };

  bool searchHasFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorWidgetOfExactType<ExplorerSearchField>() != null;
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    int times = 1,
  }) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
  }

  Future<void> focusRow(WidgetTester tester, String text) async {
    Focus.of(tester.element(find.text(text))).requestFocus();
    await tester.pumpAndSettle();
  }

  const down = LogicalKeyboardKey.arrowDown;
  const up = LogicalKeyboardKey.arrowUp;
  const left = LogicalKeyboardKey.arrowLeft;
  const right = LogicalKeyboardKey.arrowRight;

  group('up and down', () {
    testWidgets('move one row at a time, through headers and projects alike, '
        'in the order drawn', (tester) async {
      seed();
      await pump(tester);
      await focusRow(tester, 'CLIENT WORK');

      final seen = [focused()];
      for (var i = 0; i < 7; i++) {
        await press(tester, down);
        seen.add(focused());
      }
      expect(seen, [
        'CLIENT WORK',
        'alpha',
        'bravo',
        'GAME DEV',
        'charlie',
        'NO CONTEXT',
        'delta',
        'TERMINALS',
      ]);

      await press(tester, down);
      expect(focused(), 'TERMINALS', reason: 'the last row is the last row');

      await press(tester, up, times: 3);
      expect(focused(), 'charlie');
    });

    testWidgets('a held key keeps moving', (tester) async {
      seed();
      await pump(tester);
      await focusRow(tester, 'CLIENT WORK');

      await tester.sendKeyDownEvent(down);
      await tester.sendKeyRepeatEvent(down);
      await tester.sendKeyRepeatEvent(down);
      await tester.sendKeyUpEvent(down);
      await tester.pumpAndSettle();

      expect(focused(), 'GAME DEV');
    });

    testWidgets('a line of prose is not a stop', (tester) async {
      seed();
      final container = await pump(tester);
      // `bravo` holds no sessions: open, it draws a hint and nothing else.
      container.read(explorerExpandedProjectsProvider.notifier).open('p2');
      await tester.pumpAndSettle();
      expect(find.textContaining('No sessions yet'), findsOneWidget);

      await focusRow(tester, 'bravo');
      await press(tester, down);
      expect(focused(), 'GAME DEV');
      await press(tester, up);
      expect(focused(), 'bravo');
    });

    testWidgets('Home and End go to the first and the last row', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await focusRow(tester, 'charlie');

      await press(tester, LogicalKeyboardKey.end);
      expect(focused(), 'TERMINALS');
      await press(tester, LogicalKeyboardKey.home);
      expect(focused(), 'CLIENT WORK');
    });
  });

  group('right and left', () {
    testWidgets('right opens a folded project, then steps into it; left steps '
        'out to it, then folds it, then goes to its header', (tester) async {
      seed();
      final container = await pump(tester);
      Set<String> open() => container.read(explorerExpandedProjectsProvider);
      await focusRow(tester, 'alpha');

      await press(tester, right);
      expect(open(), {'p1'});
      expect(focused(), 'alpha', reason: 'opening does not move');
      expect(
        container.read(selectedProjectIdProvider),
        isNull,
        reason: 'unfolding is not opening: that is Enter',
      );

      await press(tester, right);
      expect(focused(), 'Fix login');
      await press(tester, down);
      expect(focused(), 'Add tests');
      await press(tester, right);
      expect(focused(), 'Add tests', reason: 'a session has nothing to open');

      await press(tester, left);
      expect(focused(), 'alpha', reason: 'a session\'s parent is its project');
      expect(open(), {'p1'});

      await press(tester, left);
      expect(open(), isEmpty);
      expect(focused(), 'alpha');

      await press(tester, left);
      expect(focused(), 'CLIENT WORK', reason: 'a project\'s parent');
    });

    testWidgets('a context header folds and unfolds, and right steps onto its '
        'first project', (tester) async {
      seed();
      final container = await pump(tester);
      List<String> folded() =>
          container.read(settingsControllerProvider).collapsedExplorerNodes;
      await focusRow(tester, 'CLIENT WORK');

      await press(tester, left);
      expect(folded(), ['ctx:w1']);
      expect(find.text('alpha'), findsNothing);
      expect(focused(), 'CLIENT WORK', reason: 'focus stays on what folded');

      await press(tester, left);
      expect(folded(), ['ctx:w1'], reason: 'folded already, and no parent');

      await press(tester, right);
      expect(folded(), isEmpty);
      await press(tester, right);
      expect(focused(), 'alpha');
    });

    testWidgets('Terminals opens with right and folds with left', (
      tester,
    ) async {
      seed();
      final container = await pump(tester);
      await focusRow(tester, 'TERMINALS');

      await press(tester, right);
      expect(container.read(explorerExpandedTerminalsProvider), {'windows'});
      await press(tester, right);
      expect(focused(), 'TERMINALS', reason: 'nothing under it to step onto');
      await press(tester, left);
      expect(container.read(explorerExpandedTerminalsProvider), isEmpty);
    });
  });

  group('Enter, Space and Shift', () {
    testWidgets('Enter does what a click does', (tester) async {
      seed();
      final container = await pump(tester);
      await focusRow(tester, 'charlie');

      await press(tester, LogicalKeyboardKey.enter);

      expect(container.read(explorerExpandedProjectsProvider), {'p3'});
      expect(container.read(selectedProjectIdProvider), 'p3');
    });

    testWidgets('Shift and an arrow extend the selection in selection mode, '
        'across a header', (tester) async {
      seed();
      final container = await pump(tester);
      container.read(sessionSelectionProvider.notifier).enter();
      await tester.pumpAndSettle();
      await focusRow(tester, 'alpha');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await press(tester, down);
      expect(container.read(sessionSelectionProvider).ids, {'p1', 'p2'});
      await press(tester, down);
      expect(focused(), 'GAME DEV');
      await press(tester, down);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(focused(), 'charlie');
      expect(container.read(sessionSelectionProvider).ids, {'p1', 'p2', 'p3'});

      await press(tester, LogicalKeyboardKey.space);
      expect(container.read(sessionSelectionProvider).ids, {
        'p1',
        'p2',
      }, reason: 'Space still ticks the focused row');
    });

    testWidgets('outside selection mode Shift and an arrow only move', (
      tester,
    ) async {
      seed();
      final container = await pump(tester);
      await focusRow(tester, 'alpha');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await press(tester, down);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(focused(), 'bravo');
      expect(container.read(sessionSelectionProvider).active, isFalse);
    });
  });

  group('typing', () {
    testWidgets('goes to the next row whose title starts with what was typed, '
        'and starts over after a pause', (tester) async {
      seed();
      await pump(tester);
      await focusRow(tester, 'CLIENT WORK');

      await press(tester, LogicalKeyboardKey.keyC);
      expect(focused(), 'charlie', reason: 'the next one, not this one');
      await press(tester, LogicalKeyboardKey.keyH);
      expect(focused(), 'charlie', reason: '"ch" still names it');

      await tester.pump(Latency.typeAhead);
      await press(tester, LogicalKeyboardKey.keyD);
      expect(focused(), 'delta', reason: 'a pause starts a new word');

      await tester.pump(Latency.typeAhead);
      await press(tester, LogicalKeyboardKey.keyA);
      expect(focused(), 'alpha', reason: 'it wraps past the end');

      await tester.pump(Latency.typeAhead);
      await press(tester, LogicalKeyboardKey.keyZ);
      expect(focused(), 'alpha', reason: 'nothing starts with z');
    });

    testWidgets('a letter typed again walks the rows that share it', (
      tester,
    ) async {
      seed();
      await pump(tester);
      await focusRow(tester, 'alpha');

      await press(tester, LogicalKeyboardKey.keyC);
      expect(focused(), 'charlie');
      await press(tester, LogicalKeyboardKey.keyC);
      expect(focused(), 'CLIENT WORK', reason: '"cc" names nothing: next "c"');
      await press(tester, LogicalKeyboardKey.keyC);
      expect(focused(), 'charlie');
    });

    testWidgets('a chord is not typing', (tester) async {
      seed();
      await pump(tester);
      await focusRow(tester, 'alpha');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await press(tester, LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(focused(), 'alpha');
    });
  });

  group('the search field and the list are one column', () {
    testWidgets('down leaves the field for the first row, and up on the first '
        'row returns to it', (tester) async {
      seed();
      await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(searchHasFocus(), isTrue);

      await press(tester, down);
      expect(focused(), 'CLIENT WORK');
      await press(tester, up);
      expect(searchHasFocus(), isTrue);
      expect(focused(), isNull);
    });

    testWidgets('the field keeps every key that is its own', (tester) async {
      seed();
      final container = await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'br');
      await press(tester, left);
      await press(tester, LogicalKeyboardKey.home);
      await tester.pumpAndSettle();

      expect(searchHasFocus(), isTrue);
      expect(container.read(explorerSearchQueryProvider), 'br');
      expect(find.text('alpha'), findsNothing, reason: 'it searched');

      await press(tester, down);
      expect(focused(), 'CLIENT WORK');
      await press(tester, down);
      expect(focused(), 'bravo');
    });
  });

  group('a list longer than the screen', () {
    /// Where the pinned header's lower edge is, or the list's top without one.
    double coveredTo(WidgetTester tester) {
      final header = find.descendant(
        of: find.byType(ExplorerPinnedHeader),
        matching: find.byType(ExplorerContextHeader),
      );
      return header.evaluate().isEmpty
          ? tester.getRect(find.byType(ListView)).top
          : tester.getRect(header).bottom;
    }

    Rect focusedRect(WidgetTester tester) =>
        tester.getRect(find.byWidget(focusedTreeRow()!));

    void expectInView(WidgetTester tester) {
      final list = tester.getRect(find.byType(ListView));
      final row = focusedRect(tester);
      expect(row.top, greaterThanOrEqualTo(coveredTo(tester) - 0.5));
      expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.5));
    }

    testWidgets('End reaches a row that was never built, and Home comes back', (
      tester,
    ) async {
      seed(extra: 300);
      await pump(tester, size: const Size(420, 600));
      await focusRow(tester, 'alpha');
      expect(find.text('delta', skipOffstage: false), findsNothing);

      await press(tester, LogicalKeyboardKey.end);
      expect(focused(), 'TERMINALS');
      expectInView(tester);

      await press(tester, LogicalKeyboardKey.home);
      expect(focused(), 'CLIENT WORK');
      expectInView(tester);
    });

    testWidgets('typing reaches a row that was never built', (tester) async {
      seed(extra: 300);
      await pump(tester, size: const Size(420, 600));
      await focusRow(tester, 'alpha');

      await press(tester, LogicalKeyboardKey.keyD);
      expect(focused(), 'delta');
      expectInView(tester);
    });

    testWidgets('left from deep in a context reaches its header, which has '
        'scrolled away', (tester) async {
      seed(extra: 300);
      await pump(tester, size: const Size(420, 600));
      await focusRow(tester, 'alpha');
      await press(tester, LogicalKeyboardKey.end);
      await press(tester, up, times: 6);
      expect(focused(), startsWith('extra-'));

      await press(tester, left);
      expect(focused(), 'CLIENT WORK');
      expectInView(tester);
    });

    testWidgets('Page Down and Page Up move about a screen, and keep the row '
        'in view', (tester) async {
      seed(extra: 120);
      await pump(tester, size: const Size(420, 600));
      await focusRow(tester, 'alpha');
      int index() => int.parse(focused()!.split('-').last);

      await press(tester, LogicalKeyboardKey.pageDown);
      final first = index();
      expect(first, greaterThan(4), reason: 'more than a row or two');
      expectInView(tester);
      await press(tester, LogicalKeyboardKey.pageDown);
      expect(index() - first, greaterThan(4));
      expectInView(tester);

      await press(tester, LogicalKeyboardKey.pageUp, times: 2);
      expect(focused(), anyOf('alpha', 'bravo', 'CLIENT WORK'));
      expectInView(tester);
    });

    testWidgets('focus never rests under the pinned header, whichever way it '
        'came', (tester) async {
      seed(extra: 60);
      await pump(tester, size: const Size(420, 600));
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ExplorerPinnedHeader),
          matching: find.text('CLIENT WORK'),
        ),
        findsOneWidget,
        reason: 'the header is pinned',
      );
      // A row in the middle of the screen, then up past the top edge.
      final middle = find
          .byType(ExplorerProjectRow)
          .evaluate()
          .map((element) => element.widget as ExplorerProjectRow)
          .firstWhere((row) => tester.getRect(find.byWidget(row)).top > 300);
      await focusRow(tester, middle.project.name);

      for (var i = 0; i < 14; i++) {
        await press(tester, up);
        expectInView(tester);
      }
      for (var i = 0; i < 30; i++) {
        await press(tester, down);
        expectInView(tester);
      }
    });
  });

  group('what it costs', () {
    testWidgets('moving focus rebuilds inside the two rows involved, and '
        'nothing else', (tester) async {
      seed(extra: 20);
      await pump(tester);
      await focusRow(tester, 'alpha');
      // The first key after a pointer switches Flutter's focus highlight mode,
      // which every `InkWell` on screen hears once. Not this feature's cost,
      // and the same for a Tab: measured from the second key.
      await press(tester, down);
      expect(focused(), 'bravo');

      final rows = <String>{};
      final outside = <String>[];
      debugOnRebuildDirtyWidget = (element, _) {
        String? owner;
        element.visitAncestorElements((ancestor) {
          final widget = ancestor.widget;
          if (widget is! ExplorerTreeRow) return true;
          owner = widget.node.id;
          return false;
        });
        owner == null
            ? outside.add('${element.widget.runtimeType}')
            : rows.add(owner!);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      await press(tester, down);
      debugOnRebuildDirtyWidget = null;

      expect(focused(), 'extra-000');
      expect(rows, {'project:p2', 'project:x000'});
      // Above a row there is only the framework's own bookkeeping: the focus
      // scopes that heard focus move, and the list's keep-alive around each of
      // the two rows. No panel, no list, no third row.
      expect(
        outside.toSet().difference({
          '_FocusInheritedScope',
          'AutomaticKeepAlive',
          'KeepAlive',
        }),
        isEmpty,
      );
      expect(
        outside.where((type) => type == 'KeepAlive').length,
        lessThanOrEqualTo(2),
      );
    });
  });

  group('to a screen reader', () {
    testWidgets('a project and a header say whether they are open', (
      tester,
    ) async {
      seed();
      final container = await pump(tester);
      final handle = tester.ensureSemantics();

      /// What the row named [text] says of itself: the node holding the name,
      /// or the nearest one above it that folds.
      Tristate expandedOf(String text) {
        SemanticsNode? node = tester.getSemantics(find.text(text));
        while (node != null &&
            node.flagsCollection.isExpanded == Tristate.none) {
          node = node.parent;
        }
        return node?.flagsCollection.isExpanded ?? Tristate.none;
      }

      expect(expandedOf('alpha'), Tristate.isFalse);
      expect(expandedOf('CLIENT WORK'), Tristate.isTrue);
      expect(expandedOf('TERMINALS'), Tristate.isFalse);

      container.read(explorerExpandedProjectsProvider.notifier).open('p1');
      await tester.pumpAndSettle();
      expect(expandedOf('alpha'), Tristate.isTrue);
      expect(
        tester.getSemantics(find.text('Fix login')).flagsCollection.isExpanded,
        Tristate.none,
        reason: 'a session does not fold',
      );
      handle.dispose();
    });
  });
}
