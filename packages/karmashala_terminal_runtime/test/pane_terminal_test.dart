import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:xterm2/xterm.dart';

/// A divider drag lays a pane out at every width it passes through. Each one
/// that reaches the terminal re-wraps the whole scrollback and sends the
/// process a SIGWINCH, and a TUI answers every SIGWINCH with a repaint whose
/// leftovers scroll out of its reach. So a width that is still moving waits.
///
/// `testWidgets` only for its clock: a timer under `pump` runs on fake time,
/// and [now] is moved with it.

const settle = Duration(milliseconds: 100);
const frame = Duration(milliseconds: 16);

var now = Duration.zero;

extension on WidgetTester {
  Future<void> pass(Duration time) {
    now += time;
    return pump(time);
  }
}

PaneTerminal pane({int columns = 120, int rows = 10, int maxLines = 1000}) {
  final terminal = PaneTerminal(
    maxLines: maxLines,
    settle: settle,
    now: () => now,
  )..resizeNow(columns, rows);
  for (var i = 0; i < 40; i++) {
    terminal.write('line $i ${'x' * 100}\r\n');
  }
  return terminal;
}

List<String> rowsOf(Terminal terminal) {
  final lines = terminal.mainBuffer.lines;
  return [
    for (var i = 0; i < lines.length; i++) lines[i].toString().trimRight(),
  ];
}

/// A TUI shaped like Ink's: it remembers how many rows its last frame took, and
/// answers a SIGWINCH by moving up that many, erasing down and painting at the
/// new width. It paints *after* the resize, as a process on a PTY must — by
/// then the terminal has re-wrapped the old frame's full-width rows into more
/// rows than the TUI counted, so the top of the old frame is out of its reach.
class InkShapedTui {
  InkShapedTui(this.terminal) {
    terminal.onResize = (columns, _, _, _) =>
        Future.microtask(() => paint(columns));
  }

  final Terminal terminal;
  var _rows = 0;
  var paints = 0;

  void paint(int width) {
    paints++;
    final frame = [
      '╭${'─' * (width - 2)}╮',
      '│ > ask anything${' ' * (width - 17)}│',
      '╰${'─' * (width - 2)}╯',
      '${' ' * (width - 12)}tokens@$width',
    ];
    final up = _rows > 1 ? '\x1b[${_rows - 1}A' : '';
    terminal.write('$up\r\x1b[J${frame.join('\r\n')}');
    _rows = frame.length;
  }

  /// Rows holding a piece of some frame other than the live one.
  int get leftovers {
    final lines = terminal.mainBuffer.lines;
    var found = 0;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i].toString();
      if (text.contains('─') ||
          text.contains('tokens@') ||
          text.contains('ask anything')) {
        found++;
      }
    }
    return found - _rows;
  }
}

void main() {
  setUp(() => now = Duration.zero);

  testWidgets('a drag leaves two repaints of leftovers, not one per width', (
    tester,
  ) async {
    Future<InkShapedTui> dragged(Terminal terminal) async {
      terminal.resize(160, 40);
      for (var i = 0; i < 100; i++) {
        terminal.write('transcript line $i\r\n');
      }
      final tui = InkShapedTui(terminal)..paint(160);
      await tester.pass(settle);
      for (final widths in [
        [for (var w = 159; w >= 100; w--) w],
        [for (var w = 101; w <= 160; w++) w],
      ]) {
        for (final width in widths) {
          terminal.resize(width, 40);
          await tester.pass(frame);
        }
        // The width lands, and then the hand rests before the next drag.
        await tester.pass(settle);
        await tester.pass(settle);
      }
      return tui;
    }

    final immediate = await dragged(Terminal(maxLines: 10000));
    final settled = await dragged(
      PaneTerminal(maxLines: 10000, settle: settle, now: () => now),
    );

    expect(immediate.paints, 121, reason: 'one SIGWINCH per width');
    expect(immediate.leftovers, greaterThan(100));
    expect(settled.paints, 5, reason: 'the first paint, and two per gesture');
    expect(settled.leftovers, lessThanOrEqualTo(4));
  });

  testWidgets('a drag resizes twice: its first width, then its last', (
    tester,
  ) async {
    final terminal = pane();
    final told = <(int, int)>[];
    terminal.onResize = (columns, rows, _, _) => told.add((columns, rows));

    for (var columns = 119; columns >= 80; columns--) {
      terminal.resize(columns, 10);
      await tester.pass(frame);
    }
    expect(told, [(119, 10)], reason: 'nothing more while the width moves');
    expect(terminal.viewWidth, 119);

    await tester.pass(settle);
    expect(told, [(119, 10), (80, 10)]);
    expect(terminal.viewWidth, 80);
    expect(terminal.mainBuffer.lines[0].length, 80);
  });

  testWidgets('a resize after a quiet spell is not delayed at all', (
    tester,
  ) async {
    // A first layout, a maximise, a panel toggled: one size, wanted now.
    final terminal = pane();
    terminal.resize(132, 43);
    expect((terminal.viewWidth, terminal.viewHeight), (132, 43));

    await tester.pass(settle);
    terminal.resize(96, 30);
    expect((terminal.viewWidth, terminal.viewHeight), (96, 30));
  });

  testWidgets('a grid hint does not make the first layout wait', (
    tester,
  ) async {
    final terminal = pane()..resizeNow(163, 47);
    terminal.resize(150, 47);
    expect(terminal.viewWidth, 150);
  });

  testWidgets('the settled width is what one resize would have given', (
    tester,
  ) async {
    final dragged = pane();
    for (final columns in [110, 97, 80, 61, 44, 61, 75]) {
      dragged.resize(columns, 10);
      await tester.pass(frame);
    }
    await tester.pass(settle);

    final direct = pane()..resize(75, 10);
    expect(rowsOf(dragged), rowsOf(direct));
  });

  testWidgets('the render object asking again does not start the wait over', (
    tester,
  ) async {
    // It asks at every layout until the terminal has the grid of its box.
    final terminal = pane()..resize(100, 10);
    terminal.resize(90, 10);
    for (var i = 0; i < 9; i++) {
      await tester.pass(const Duration(milliseconds: 10));
      terminal.resize(90, 10);
    }
    await tester.pass(const Duration(milliseconds: 10));
    expect(terminal.viewWidth, 90);
  });

  testWidgets('rows move at once while the columns wait', (tester) async {
    final terminal = pane()..resize(110, 10);
    final told = <(int, int)>[];
    terminal.onResize = (columns, rows, _, _) => told.add((columns, rows));

    terminal.resize(90, 20);
    expect((terminal.viewWidth, terminal.viewHeight), (110, 20));
    expect(told, [(110, 20)]);

    await tester.pass(settle);
    expect((terminal.viewWidth, terminal.viewHeight), (90, 20));
    expect(told, [(110, 20), (90, 20)]);
  });

  testWidgets('a width that comes back to where it was is no resize at all', (
    tester,
  ) async {
    final terminal = pane()..resize(110, 10);
    var told = 0;
    terminal.onResize = (_, _, _, _) => told++;

    terminal.resize(100, 10);
    terminal.resize(110, 10);
    await tester.pass(settle);
    expect(told, 0);
    expect(terminal.viewWidth, 110);
  });

  testWidgets('the view is told to lay out again when the width lands', (
    tester,
  ) async {
    final terminal = pane()..resize(110, 10);
    var changes = 0;
    terminal.addListener(() => changes++);

    terminal.resize(90, 10);
    await tester.pass(settle);
    expect(changes, 1);
  });
}
