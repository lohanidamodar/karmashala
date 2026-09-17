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

/// **One gutter down each side of the tree**, for every row kind the Explorer
/// draws: carets step in by [ExplorerRow.indent] per depth, and counts, ages,
/// `+` and `⋮` end in one right-hand column. `explorer_tree_alignment_test`
/// measures the same on the real panel; this pins the kit rows at the edges —
/// the pane minimum and large text.
const double _width = 400;

void main() {
  Widget tree() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExplorerHeaderRow(
        depth: 0,
        expanded: true,
        label: 'archlinux',
        icon: AppIcons.terminalWindow,
        emphasis: HeaderEmphasis.machine,
        trailingText: '4',
        trailingTooltip: '4 projects',
        onTap: () {},
        action: ExplorerRowAction(
          tooltip: 'Open a terminal on archlinux',
          icon: AppIcons.plus,
          onPressed: () {},
        ),
      ),
      ExplorerHeaderRow(
        depth: 1,
        expanded: true,
        label: 'Projects',
        trailingText: '4',
        onTap: () {},
      ),
      ExplorerHeaderRow(
        depth: 1,
        expanded: true,
        label: 'Terminals',
        detail: 'read 21 minutes ago',
        trailingText: '1',
        onTap: () {},
      ),
      TerminalRow(
        terminal: const EnvironmentTerminal(
          id: 't1',
          label: 'zsh',
          running: true,
          paneId: 'p1',
        ),
        depth: 2,
        onOpen: () {},
      ),
      ProjectCard(
        depth: 2,
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
        depth: 3,
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
    for (final text in ['4', '1', '34']) {
      for (final element in find.text(text).evaluate()) {
        expect(
          rightOf(tester, find.byWidget(element.widget)),
          moreOrLessEquals(column, epsilon: 0.5),
          reason: '"$text" ends off the column',
        );
      }
    }
  });

  testWidgets('carets step in by one indent per depth', (tester) async {
    await pumpTree(tester);

    final carets =
        find
            .byWidgetPredicate((w) => w is Icon && w.icon == AppIcons.caretDown)
            .evaluate()
            .map((e) => tester.getCenter(find.byWidget(e.widget)).dx)
            .toSet()
            .toList()
          ..sort();
    // Depth 0, 1 and the project at 2.
    expect(carets, hasLength(3));
    expect(carets[1] - carets[0], ExplorerRow.indent);
    expect(carets[2] - carets[1], ExplorerRow.indent);
  });

  testWidgets('a machine and a project put their + in one column on hover', (
    tester,
  ) async {
    await pumpTree(tester);
    const machinePlus = 'Open a terminal on archlinux';
    const projectPlus = 'Start a session here with the default agent';
    expect(find.byTooltip(machinePlus), findsNothing);

    await hover(tester, find.text('archlinux'));
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
