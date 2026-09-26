import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/environment_terminals.dart';
import 'package:karmashala/src/features/explorer/presentation/environment_rows.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// **One gutter down each side of the list**, for every row kind the Explorer
/// draws: a group's header and the projects under it share depth zero, a
/// session steps in by [ExplorerRow.indent], and counts, ages, `+` and `⋮` end
/// in one right-hand column. `explorer_tree_alignment_test`
/// measures the same on the real panel; this pins the kit rows at the edges —
/// the pane minimum and large text.
const double _width = 400;

void main() {
  Widget tree() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExplorerGroupHeader(
        expanded: true,
        label: 'Game dev',
        trailingText: '4',
        trailingWords: '4 projects',
        onTap: () {},
        menuItemsBuilder: () => const [],
        onMenu: (_) {},
      ),
      ExplorerGroupHeader(
        expanded: true,
        label: 'archlinux · Terminals',
        detail: 'read 21 minutes ago',
        trailingText: '1',
        onTap: () {},
        action: ExplorerRowAction(
          tooltip: 'Open a terminal on archlinux',
          icon: AppIcons.plus,
          onPressed: () {},
        ),
      ),
      TerminalRow(
        terminal: const EnvironmentTerminal(
          id: 't1',
          label: 'zsh',
          running: true,
          paneId: 'p1',
        ),
        depth: 0,
        onOpen: () {},
      ),
      ProjectCard(
        depth: 0,
        name: 'popubits',
        path: r'/mnt/c/Users/me/projects/popupbits',
        expanded: true,
        selected: false,
        summary: const ProjectSummary(sessions: 34),
        onTap: () {},
        onNewSession: () {},
        menuItemsBuilder: () => const [],
        onMenu: (_) {},
      ),
      SessionCard(
        depth: 1,
        selected: false,
        agentIcon: AppIcons.checkCircle,
        agentLabel: 'Claude Code',
        title: 'Benchmark arcade games',
        age: '22h 3m',
        branch: 'main',
        onTap: () {},
        menuItemsBuilder: () => const [],
        onMenu: (_) {},
      ),
    ],
  );

  Future<void> pumpTree(
    WidgetTester tester, {
    double width = _width,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
        builder: (context, inner) => UiDensity.wrap(context, inner!),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(child: tree()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double rightOf(WidgetTester tester, Finder finder) =>
      tester.getTopRight(finder).dx;

  TestGesture? mouse;
  Future<void> hover(WidgetTester tester, Finder finder) async {
    var gesture = mouse;
    if (gesture == null) {
      gesture = mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(() async {
        await mouse?.removePointer();
        mouse = null;
      });
    }
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
  }

  testWidgets('every count and age ends in the same column', (tester) async {
    await pumpTree(tester);

    final column = rightOf(tester, find.text('22h 3m'));
    // Words where the row has room, a header's bare number — one edge.
    for (final text in ['4', '1', '34 sessions']) {
      expect(find.text(text), findsWidgets, reason: '"$text" is not drawn');
      for (final element in find.text(text).evaluate()) {
        expect(
          rightOf(tester, find.byWidget(element.widget)),
          moreOrLessEquals(column, epsilon: 0.5),
          reason: '"$text" ends off the column',
        );
      }
    }
  });

  testWidgets('a count is said in words while the title keeps its room, and '
      'as a bare number under that — on the same edge', (tester) async {
    await pumpTree(tester);
    final wide = rightOf(tester, find.text('34 sessions'));
    // A header's label already says what it counts: a number, and the words
    // as its tooltip, at every width.
    expect(find.text('4 projects'), findsNothing);
    expect(find.byTooltip('4 projects'), findsOneWidget);

    await pumpTree(tester, width: 240);
    expect(find.text('34 sessions'), findsNothing);
    expect(find.byTooltip('4 projects'), findsOneWidget);
    expect(find.text('34'), findsOneWidget);
    // The pane is 160px narrower, and so is where its counts end.
    expect(
      rightOf(tester, find.text('34')),
      moreOrLessEquals(wide - 160, epsilon: 0.5),
    );
    expect(
      rightOf(tester, find.text('34')),
      moreOrLessEquals(rightOf(tester, find.text('22h 3m')), epsilon: 0.5),
    );
  });

  testWidgets('a second line hangs at its own title, on every kind', (
    tester,
  ) async {
    await pumpTree(tester);
    double leftOf(Finder finder) => tester.getTopLeft(finder).dx;

    expect(
      leftOf(find.textContaining('popupbits')),
      moreOrLessEquals(leftOf(find.text('popubits')), epsilon: 0.5),
      reason: 'the project\'s path hangs at the project\'s name',
    );
    expect(
      leftOf(find.textContaining('Claude Code')),
      moreOrLessEquals(
        leftOf(find.text('Benchmark arcade games')),
        epsilon: 0.5,
      ),
      reason: 'the session\'s meta hangs at the session\'s title',
    );
    // One indent apart, as their carets and glyphs are.
    expect(
      leftOf(find.textContaining('Claude Code')) -
          leftOf(find.textContaining('popupbits')),
      ExplorerRow.indent,
    );
  });

  testWidgets('a header and the projects under it share one caret column', (
    tester,
  ) async {
    await pumpTree(tester);

    final carets = find
        .byWidgetPredicate((w) => w is Icon && w.icon == AppIcons.caretDown)
        .evaluate()
        .map((e) => tester.getCenter(find.byWidget(e.widget)).dx)
        .toSet();
    // Two headers and a project: a header is a label, not a level.
    expect(carets, hasLength(1));
  });

  testWidgets('a header\'s words start where a project\'s name does', (
    tester,
  ) async {
    await pumpTree(tester);

    final label = tester.getTopLeft(find.text('GAME DEV')).dx;
    final name = tester.getTopLeft(find.text('popubits')).dx;
    expect(
      name - label,
      0,
      reason:
          'a header keeps the glyph column for its colour dot, coloured or '
          'not, so every label and every name start on one edge',
    );
  });

  testWidgets('a header and a project put their + in one column on hover', (
    tester,
  ) async {
    await pumpTree(tester);
    const machinePlus = 'Open a terminal on archlinux';
    const projectPlus = 'Start a session here with the default agent';
    expect(find.byTooltip(machinePlus), findsNothing);

    await hover(tester, find.text('ARCHLINUX · TERMINALS'));
    final machine = tester.getCenter(find.byTooltip(machinePlus)).dx;
    await hover(tester, find.text('popubits'));
    final project = tester.getCenter(find.byTooltip(projectPlus)).dx;

    expect(machine, moreOrLessEquals(project, epsilon: 0.5));
  });

  testWidgets('the menu and a terminal row\'s verb end where the counts do', (
    tester,
  ) async {
    await pumpTree(tester);
    final column = rightOf(tester, find.text('22h 3m'));

    expect(
      rightOf(tester, find.widgetWithText(TextButton, 'Focus')),
      moreOrLessEquals(column, epsilon: 0.5),
    );
    await hover(tester, find.text('popubits'));
    expect(
      rightOf(tester, find.byType(RowMenuButton).first),
      moreOrLessEquals(column, epsilon: 0.5),
    );
  });

  testWidgets('swapping the count for the verbs moves nothing', (tester) async {
    await pumpTree(tester);
    final title = tester.getRect(find.text('Benchmark arcade games'));
    final name = tester.getRect(find.text('popubits'));

    await hover(tester, find.text('Benchmark arcade games'));
    expect(tester.getRect(find.text('Benchmark arcade games')), title);
    await hover(tester, find.text('popubits'));
    expect(tester.getRect(find.text('popubits')), name);
  });

  for (final (width, scale) in [(200.0, 1.0), (200.0, 2.0), (240.0, 1.3)]) {
    testWidgets('fits a ${width.toInt()}px pane at ${scale}x text', (
      tester,
    ) async {
      await pumpTree(tester, width: width, textScale: scale);
      expect(tester.takeException(), isNull);

      await hover(tester, find.text('popubits'));
      expect(tester.takeException(), isNull);
    });
  }
}
