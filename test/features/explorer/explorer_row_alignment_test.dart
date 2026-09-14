import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/environment_terminals.dart';
import 'package:karmashala/src/features/explorer/presentation/environment_rows.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

/// **One gutter down the right-hand edge of the tree.**
///
/// The owner reported it as "fix these alignments": a machine's `9 projects+`
/// and a project's `34 sessions+` ran into their own buttons, and the two
/// counts ended in different columns — a header's ended ~90px short of a
/// project's, because the header's label was `Flexible` beside an `Expanded`
/// trailing and the label's unused share became dead space after the buttons.
const double _width = 400;

void main() {
  Future<void> pumpTree(WidgetTester tester, {double width = _width}) =>
      tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExplorerHeaderRow(
                depth: 0,
                expanded: true,
                label: 'archlinux',
                icon: AppIcons.terminalWindow,
                emphasis: HeaderEmphasis.machine,
                trailingText: '4 projects',
                onTap: () {},
                actions: [
                  ExplorerRowAction(
                    tooltip: 'Open a terminal on archlinux',
                    icon: AppIcons.plus,
                    onPressed: () {},
                  ),
                ],
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
                trailingText: 'read 21 minutes ago',
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
                name: 'popubits',
                path: r'/mnt/c/Users/me/projects/popupbits',
                expanded: false,
                selected: false,
                summary: const ProjectSummary(sessions: 34),
                onTap: () {},
                onNewSession: () {},
                menuItemsBuilder: () => const [],
                onMenu: (_) {},
              ),
            ],
          ),
        ),
      ),
    ),
  );

  /// The right edge of a widget, in the tree's own coordinates.
  double rightOf(WidgetTester tester, Finder finder) =>
      tester.getTopRight(finder).dx;

  testWidgets('every count ends in the same column', (tester) async {
    await pumpTree(tester);

    final machine = rightOf(tester, find.text('4 projects'));
    final section = rightOf(tester, find.text('4'));
    final project = rightOf(tester, find.textContaining('34 sessions'));

    expect(machine, moreOrLessEquals(project, epsilon: 1));
    expect(section, moreOrLessEquals(project, epsilon: 1));
  });

  testWidgets('a count never touches the button beside it', (tester) async {
    await pumpTree(tester);

    final countRight = rightOf(tester, find.text('4 projects'));
    final plusLeft = tester
        .getTopLeft(find.widgetWithIcon(IconButton, AppIcons.plus).first)
        .dx;

    // A real gap, not a hairline: `9 projects+` was one glyph run to the eye.
    expect(plusLeft - countRight, greaterThanOrEqualTo(6));
  });

  testWidgets('a machine and a project put their + in one column', (
    tester,
  ) async {
    await pumpTree(tester);

    final plusButtons = find.widgetWithIcon(IconButton, AppIcons.plus);
    expect(plusButtons, findsNWidgets(2));
    expect(
      tester.getTopLeft(plusButtons.at(0)).dx,
      moreOrLessEquals(tester.getTopLeft(plusButtons.at(1)).dx, epsilon: 1),
    );
  });

  testWidgets('a terminal row ends where the tree does', (tester) async {
    await pumpTree(tester);

    // The row's last verb and a project's `⋮` are the tree's right edge; the
    // terminal row used to stand 6px outside it.
    expect(
      rightOf(tester, find.widgetWithText(TextButton, 'Focus')),
      moreOrLessEquals(
        rightOf(tester, find.byType(RowMenuButton)),
        epsilon: 1,
      ),
    );
  });

  testWidgets('the narrowest pane the Explorer allows still fits', (
    tester,
  ) async {
    // 200px is the column's clamp, and "read 21 minutes ago" is the longest
    // thing a section header says. The count gives way, never the row.
    await pumpTree(tester, width: 200);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a header row uses the width it is given', (tester) async {
    await pumpTree(tester);

    // The dead-space bug measured directly: the label took half the free width
    // whatever it needed, and what it did not use fell off the right end.
    final plus = find.widgetWithIcon(IconButton, AppIcons.plus).first;
    expect(tester.getTopRight(plus).dx, greaterThan(_width - 40));
  });
}
