import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// What a pane is *told* it is, against the box it is *drawn* in, as the window
/// changes size.
///
/// The report was "resizing doesn't work as expected", narrowed by the owner to
/// resizing the window rather than dragging a split. The failure that shape
/// describes is a grid the process disagrees with: a CLI told 109 columns and
/// drawn 60 wide wraps its long lines two thirds of the way across, puts a
/// TUI's right border off the edge and leaves its footer in the wrong place —
/// and on a pane whose process has exited nothing ever redraws it away.
///
/// So this compares the two numbers directly, at every window shape the app
/// supports, including the wide-and-short one the report came with. What the
/// terminal is told is what the pane hands `Pty.resize`, one line further on
/// (`terminal_instance.dart`), so a mismatch here is the whole bug and a match
/// here rules the widget layer out. Whether the *process* then believes it is a
/// question no widget test can answer; `test/terminal/live_pane_resize_test.dart`
/// asks a real one.
///
/// The window matrix could not have caught any of this. It pumps a surface at
/// fixed sizes and checks overflow, focus and semantics — never that a
/// character grid agrees with its box, and never one size after another in the
/// same pane, which is what resizing is.
void main() {
  ProviderContainer panelContainer() {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final container = fakeTerminalContainer(database: database);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpPanel(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pump();
  }

  void resizeWindow(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  /// The render object that decides the grid, dug out of the pane's view.
  RenderTerminal renderTerminalOf(WidgetTester tester, Finder view) {
    RenderTerminal? found;
    void walk(RenderObject node) {
      if (node is RenderTerminal) found ??= node;
      node.visitChildren(walk);
    }

    walk(tester.renderObject(view));
    return found!;
  }

  /// The grid that fits in the box the pane is drawn in.
  ({int columns, int rows}) drawnGrid(WidgetTester tester, Finder view) {
    final render = renderTerminalOf(tester, view);
    final cell = render.painter.cellSize;
    return (
      columns: render.size.width ~/ cell.width,
      rows: render.size.height ~/ cell.height,
    );
  }

  ({int columns, int rows}) toldGrid(Terminal terminal) =>
      (columns: terminal.viewWidth, rows: terminal.viewHeight);

  // 720x560 is the app's minimum window (`main.dart`); 1440x560 is the wide,
  // short one the report arrived with.
  const windows = [
    Size(1440, 900),
    Size(1440, 560),
    Size(720, 560),
    Size(1000, 700),
    Size(1440, 900),
  ];

  testWidgets('a pane is told the grid it is drawn in, at every window size', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    resizeWindow(tester, windows.first);
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    final terminal = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(
          container
              .read(terminalSessionsControllerProvider)
              .activeTab!
              .layout
              .panes
              .single,
        )!
        .terminal;
    final view = find.byType(TerminalView);

    for (final window in windows) {
      resizeWindow(tester, window);
      await tester.pump();
      expect(
        toldGrid(terminal),
        drawnGrid(tester, view),
        reason: 'at $window the pane believes a grid it is not drawn in',
      );
    }
  });

  testWidgets('both panes of a split are, and they are not the same grid', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    resizeWindow(tester, windows.first);
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    controller.splitPaneWith(SplitAxis.vertical, TerminalProfile.commandPrompt);
    await pumpPanel(tester, container);

    final panes = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes;
    final views = find.byType(TerminalView);

    for (final window in windows) {
      resizeWindow(tester, window);
      await tester.pump();
      for (var i = 0; i < panes.length; i++) {
        expect(
          toldGrid(controller.instanceFor(panes[i])!.terminal),
          drawnGrid(tester, views.at(i)),
          reason: 'at $window pane $i believes a grid it is not drawn in',
        );
      }
    }
  });

  testWidgets('a pane whose process has exited resizes like a live one', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    resizeWindow(tester, windows.first);
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    // The state the report's screenshot was in: `[process exited with code 1]`,
    // which keeps the pane (a clean exit in a split closes it) and puts a status
    // bar above the grid — so the box the terminal is drawn in is not the one it
    // had a moment ago.
    final instance = controller.instanceFor(paneId)! as FakeTerminalInstance;
    instance.exitCode = 1;
    instance.livenessNotifier.value = PaneLiveness.exited;
    await tester.pump();

    final view = find.byType(TerminalView);
    for (final window in windows) {
      resizeWindow(tester, window);
      await tester.pump();
      expect(
        toldGrid(instance.terminal),
        drawnGrid(tester, view),
        reason: 'at $window an ended pane believes a grid it is not drawn in',
      );
    }
  });

  testWidgets('a long line is rewrapped to the new width, not left at the old', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    resizeWindow(tester, windows.first);
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    final terminal = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(
          container
              .read(terminalSessionsControllerProvider)
              .activeTab!
              .layout
              .panes
              .single,
        )!
        .terminal;

    // Wider than any of the windows below, so every one of them has to wrap it
    // somewhere different.
    final written = List.generate(
      26,
      (i) => String.fromCharCode(97 + i) * 10,
    ).join();
    terminal.write('$written\r\n');
    await tester.pump();

    for (final window in windows) {
      resizeWindow(tester, window);
      await tester.pump();
      final rows = terminalTailLines(
        terminal,
        lines: 60,
      ).where((line) => line.isNotEmpty).toList();
      expect(
        rows.join(),
        written,
        reason: 'at $window the text did not survive the rewrap',
      );
      expect(
        rows.first.length,
        terminal.viewWidth,
        reason: 'at $window it is still wrapped at some other width',
      );
    }
  });

  testWidgets('a pane a program resized is put back into its own box', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    resizeWindow(tester, windows.first);
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    final terminal = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(
          container
              .read(terminalSessionsControllerProvider)
              .activeTab!
              .layout
              .panes
              .single,
        )!
        .terminal;
    final view = find.byType(TerminalView);
    final box = drawnGrid(tester, view);
    expect(toldGrid(terminal), box);

    // `CSI 8 ; rows ; cols t` — XTWINOPS, "set the window size in characters".
    // A program in the pane can send it, and this is the one path that changes
    // the terminal's grid without the render object being the one that did it.
    // The box still decides, so the pane has to be put back.
    terminal.write('\x1b[8;10;40t');
    await tester.pump();
    await tester.pump();

    expect(
      toldGrid(terminal),
      box,
      reason:
          'a program moved the grid out from under the widget and nothing put '
          'it back: the pane is drawn in one grid and believes another, and '
          'stays that way until the box changes by a whole cell',
    );
  });

  testWidgets('the invariant holds through interleaved resizes and switches', (
    tester,
  ) async {
    // The owner's last word was "only happening randomly when i resize the
    // window", which is the shape of a race rather than of a size. So: drive
    // the things that can interleave with a resize — a tab switch, a pane
    // coming forward out of a region, a program setting the grid itself, and
    // sub-cell window steps that change the box without changing the grid —
    // and check the invariant after every one of them rather than at the end.
    addTearDown(tester.view.reset);
    resizeWindow(tester, const Size(1200, 800));
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final first = controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);
    controller.splitPaneWith(SplitAxis.vertical, TerminalProfile.commandPrompt);
    await tester.pump();
    final second = controller.openTab(TerminalProfile.commandPrompt);
    await tester.pump();

    void checkEveryVisiblePane(String step) {
      final views = find.byType(TerminalView);
      final panes = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .visiblePanes
          .toList();
      expect(
        tester.widgetList(views),
        hasLength(panes.length),
        reason: 'after $step',
      );
      for (var i = 0; i < panes.length; i++) {
        expect(
          toldGrid(controller.instanceFor(panes[i])!.terminal),
          drawnGrid(tester, views.at(i)),
          reason: 'after $step, pane $i believes a grid it is not drawn in',
        );
      }
    }

    Future<void> step(String label, void Function() act) async {
      act();
      await tester.pump();
      await tester.pump();
      checkEveryVisiblePane(label);
    }

    await step('a resize', () => resizeWindow(tester, const Size(1000, 640)));
    await step('a tab switch', () => controller.activateTab(first));
    // Sub-cell: the box moves, the grid mostly does not, and the render object
    // takes its "nothing changed" path — which is where a stale grid hides.
    for (var i = 1; i <= 6; i++) {
      await step(
        'a $i px nudge',
        () =>
            resizeWindow(tester, Size(1000 + i.toDouble(), 640 + i.toDouble())),
      );
    }
    await step(
      'a program setting the grid',
      () => controller
          .instanceFor(
            container
                .read(terminalSessionsControllerProvider)
                .activeTab!
                .layout
                .visiblePanes
                .first,
          )!
          .terminal
          .write('\x1b[8;12;44t'),
    );
    await step('a resize straight after it', () {
      resizeWindow(tester, const Size(1440, 560));
    });
    await step('switching back', () => controller.activateTab(second));
    await step('and back again', () => controller.activateTab(first));
  });
}
