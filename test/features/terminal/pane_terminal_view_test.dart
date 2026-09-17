import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pane_terminal.dart';
import 'package:xterm2/xterm.dart';

/// [PaneTerminal] under the render object that drives it: the view asks for the
/// grid of its box at every layout, and has to end up holding it.
void main() {
  RenderTerminal renderOf(WidgetTester tester) {
    RenderTerminal? found;
    void walk(RenderObject node) {
      if (node is RenderTerminal) found ??= node;
      node.visitChildren(walk);
    }

    walk(tester.renderObject(find.byType(TerminalView)));
    return found!;
  }

  int columnsThatFit(WidgetTester tester) {
    final render = renderOf(tester);
    return render.size.width ~/ render.painter.cellSize.width;
  }

  Future<void> pumpAt(WidgetTester tester, Terminal terminal, double width) =>
      tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 400,
              child: TerminalView(terminal, padding: EdgeInsets.zero),
            ),
          ),
        ),
      );

  testWidgets('a pane dragged narrower and wider ends on the grid of its box', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);

    var now = Duration.zero;
    Future<void> pass(Duration time) {
      now += time;
      return tester.pump(time);
    }

    final terminal = PaneTerminal(maxLines: 2000, now: () => now);
    final told = <int>[];
    await pumpAt(tester, terminal, 1200);
    final wide = columnsThatFit(tester);
    expect(terminal.viewWidth, wide, reason: 'the first layout is not delayed');

    for (var i = 0; i < 200; i++) {
      terminal.write('history $i ${'y' * (wide - 20)}\r\n');
    }
    terminal.onResize = (columns, _, _, _) => told.add(columns);
    await pass(kColumnResizeSettle);

    for (var width = 1180.0; width >= 700; width -= 20) {
      await pumpAt(tester, terminal, width);
      await pass(const Duration(milliseconds: 16));
    }
    expect(told, hasLength(1), reason: 'the first width of the drag, at once');
    expect(terminal.viewWidth, told.single, reason: 'drawn clipped meanwhile');
    expect(tester.takeException(), isNull);

    await pass(kColumnResizeSettle);
    await tester.pump();
    final narrow = columnsThatFit(tester);
    expect(narrow, lessThan(told.first));
    expect(told, [told.first, narrow]);
    expect(terminal.viewWidth, narrow);
    await pass(kColumnResizeSettle);

    for (var width = 720.0; width <= 1200; width += 20) {
      await pumpAt(tester, terminal, width);
      await pass(const Duration(milliseconds: 16));
    }
    await pass(kColumnResizeSettle);
    await tester.pump();
    expect(told, hasLength(4));
    expect(told.last, wide);
    expect(terminal.viewWidth, columnsThatFit(tester));
    expect(tester.takeException(), isNull);
  });
}
