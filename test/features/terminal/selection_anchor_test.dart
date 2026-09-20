import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// A selection is a range of the *buffer*, not of the screen.
///
/// `TerminalGestureHandler.onDragUpdate` hands the render object the screen
/// position the drag began at on every update, and that was fed back through
/// `getCellOffset`, which adds the **current** scroll offset. So the moment the
/// buffer moved under the pointer — output arriving, or the view scrolling —
/// the start of the selection slid onto a different line and everything that
/// had scrolled off the top fell out of it. Select a build log while it is
/// still printing and you got the last screen, not what you dragged over.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    container = fakeTerminalContainer(database: db);
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<TerminalInstance> pumpPane(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    return controller.instanceFor(tab.focusedPaneId)!;
  }

  /// The screen position of the centre of cell ([column], [row]).
  Offset cell(WidgetTester tester, int column, int row) {
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final size = render.cellSize;
    return render.localToGlobal(
      render.getOffset(CellOffset(column, row)) +
          Offset(size.width / 2, size.height / 2),
    );
  }

  testWidgets('output arriving mid-drag does not move the start', (
    tester,
  ) async {
    final instance = await pumpPane(tester);
    final terminal = instance.terminal;
    for (var i = 0; i < 5; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();

    // Start a drag on the first line, at the very top of the buffer.
    final gesture = await tester.startGesture(
      cell(tester, 0, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pumpAndSettle();

    final beforeOutput = terminal.buffer.getText(
      instance.controller.selection!,
    );
    expect(beforeOutput, startsWith('line 0'));

    // The process keeps printing. Enough to push the whole screen up.
    for (var i = 0; i < 60; i++) {
      terminal.write('noise $i\r\n');
    }
    await tester.pumpAndSettle();

    // Extend the drag by a hair, which is what an update does.
    await gesture.moveBy(const Offset(6, 0));
    await tester.pumpAndSettle();

    final selection = instance.controller.selection!;
    expect(
      selection.begin.y,
      0,
      reason:
          'the selection still starts on the buffer line the drag did, '
          'not on whatever is at that point on the screen now',
    );
    expect(terminal.buffer.getText(selection), startsWith('line 0'));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('scrolling the view mid-drag does not move the start', (
    tester,
  ) async {
    final instance = await pumpPane(tester);
    final terminal = instance.terminal;
    for (var i = 0; i < 200; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();

    final anchorRow = terminal.buffer.lines.length - 3;
    final gesture = await tester.startGesture(
      cell(tester, 0, anchorRow),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(instance.controller.selection!.begin.y, anchorRow);

    // The user scrolls to the top while still holding the button. The moving
    // end follows the pointer, which is now over a much earlier line — so the
    // range grows, and the anchor becomes its *end*.
    instance.scrollController.jumpTo(0);
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(6, 0));
    await tester.pumpAndSettle();

    final selection = instance.controller.selection!;
    expect(
      [selection.begin.y, selection.end.y],
      contains(anchorRow),
      reason:
          'the anchor is a buffer line, not a pixel row: scrolling moves '
          'the end of the drag, never its start',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a fresh drag starts where the new drag started', (tester) async {
    // The anchor is per-drag, not sticky: pressing again re-anchors.
    final instance = await pumpPane(tester);
    final terminal = instance.terminal;
    for (var i = 0; i < 5; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();

    final first = await tester.startGesture(
      cell(tester, 0, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await first.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();
    await first.up();
    await tester.pumpAndSettle();

    final second = await tester.startGesture(
      cell(tester, 0, 2),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await second.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(
      instance.controller.selection!.begin.y,
      2,
      reason: 'the anchor is per-drag, not sticky',
    );

    await second.up();
    await tester.pumpAndSettle();
  });
}
