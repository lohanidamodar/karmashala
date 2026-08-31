import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/git/application/remote_links.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'fake_instance.dart';

/// Clicking a link in the terminal.
///
/// "links are not clickable in chitragupta's terminal" — they are now, on
/// Ctrl+click, with the hover saying so. The browser is never reached: the
/// opener is the injected `openExternalUrlProvider` seam.
void main() {
  late AppDatabase db;
  late List<String> opened;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    opened = [];
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        openExternalUrlProvider.overrideWithValue((url) async {
          opened.add(url);
          return true;
        }),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  /// Pumps the workbench, writes [output] into its one pane, and returns that
  /// pane's instance.
  Future<TerminalInstance> pumpWithOutput(
    WidgetTester tester,
    String output,
  ) async {
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
    final instance = controller.instanceFor(tab.focusedPaneId)!;
    instance.terminal.write(output);
    await tester.pumpAndSettle();
    return instance;
  }

  /// The screen position of the centre of cell ([column], [row]).
  ///
  /// Asked of the render object rather than computed from a font size: the
  /// cell metrics are the terminal's, and a test that guessed them would be
  /// testing its own arithmetic.
  Offset centreOfCell(WidgetTester tester, int column, int row) {
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final cell = render.cellSize;
    return render.localToGlobal(
      render.getOffset(CellOffset(column, row)) +
          Offset(cell.width / 2, cell.height / 2),
    );
  }

  Future<TestGesture> hover(WidgetTester tester, Offset position) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(() => mouse.removePointer());
    await mouse.moveTo(position);
    await tester.pumpAndSettle();
    return mouse;
  }

  testWidgets('hovering a URL highlights it and says how to open it', (
    tester,
  ) async {
    final instance = await pumpWithOutput(tester, 'see https://example.com/a');

    await hover(tester, centreOfCell(tester, 6, 0));

    expect(
      instance.controller.highlights,
      hasLength(1),
      reason: 'the URL under the pointer is highlighted, buffer-anchored',
    );
    expect(find.textContaining('click to open'), findsOneWidget);
    expect(find.textContaining('https://example.com/a'), findsOneWidget);
    // And the pointer says it is over something clickable.
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).mouseCursor,
      SystemMouseCursors.click,
    );
  });

  testWidgets('ordinary output is inert', (tester) async {
    final instance = await pumpWithOutput(tester, r'PS C:\Users\me> git status');

    await hover(tester, centreOfCell(tester, 4, 0));

    expect(instance.controller.highlights, isEmpty);
    expect(find.textContaining('click to open'), findsNothing);
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).mouseCursor,
      SystemMouseCursors.text,
    );
  });

  testWidgets('leaving the pane drops the highlight', (tester) async {
    final instance = await pumpWithOutput(tester, 'see https://example.com/a');
    final mouse = await hover(tester, centreOfCell(tester, 6, 0));
    expect(instance.controller.highlights, hasLength(1));

    await mouse.moveTo(const Offset(5000, 5000));
    await tester.pumpAndSettle();

    expect(instance.controller.highlights, isEmpty);
    expect(find.textContaining('click to open'), findsNothing);
  });

  testWidgets('Ctrl+click opens the URL', (tester) async {
    await pumpWithOutput(tester, 'see https://example.com/a');
    final target = centreOfCell(tester, 6, 0);
    final mouse = await hover(tester, target);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await mouse.down(target);
    await tester.pump();
    await mouse.up();
    // xterm's gesture detector arms a 300 ms double-tap timer on every tap;
    // let it expire, or the test ends with it pending.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(opened, ['https://example.com/a']);
  });

  testWidgets('a plain click does not open anything', (tester) async {
    // A click in a terminal places a selection, and when the program has asked
    // for mouse reporting it is an event the program receives. Opening a
    // browser as a side effect of clicking anywhere would be wrong.
    await pumpWithOutput(tester, 'see https://example.com/a');
    final target = centreOfCell(tester, 6, 0);
    final mouse = await hover(tester, target);

    await mouse.down(target);
    await tester.pump();
    await mouse.up();
    // xterm's gesture detector arms a 300 ms double-tap timer on every tap;
    // let it expire, or the test ends with it pending.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
  });

  testWidgets('Ctrl+click away from the link opens nothing', (tester) async {
    await pumpWithOutput(tester, 'see https://example.com/a');
    // Hover the URL first, so a stale hover cannot be what answers the click.
    final mouse = await hover(tester, centreOfCell(tester, 6, 0));
    final elsewhere = centreOfCell(tester, 1, 0);
    await mouse.moveTo(elsewhere);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await mouse.down(elsewhere);
    await tester.pump();
    await mouse.up();
    // xterm's gesture detector arms a 300 ms double-tap timer on every tap;
    // let it expire, or the test ends with it pending.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(opened, isEmpty);
  });
}
