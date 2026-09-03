import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/terminal_layout_dao.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/scrollback_limits.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// What **displaying** a restored pane costs, which is the half of the resume
/// report that has nothing to do with starting anything.
///
/// A [DormantTerminalInstance] parses its stored scrollback the first time
/// something asks to see it, inside `build`. Nothing stored says how wide the
/// pane was, so that parse used to happen at xterm's default 80 columns and
/// the workbench then reflowed every line of it to the pane's real width in
/// the same frame — the text wrapped on the way in and unwrapped again on the
/// way out, and neither shape ever drawn. Measured on this machine at a full
/// durable window (256 KiB, 2 000 lines): 2.8-9.1 ms to parse plus 0.6-4.3 ms
/// to reflow, against 2.5-6.3 ms to parse straight into the size it is shown
/// at. That is paid per restored tab the user switches to, with no process
/// starting at all, which is exactly what "switching to another was very laggy"
/// describes.
///
/// So the restored panes tell each other how wide the workbench draws a pane
/// ([TerminalGridHint]). These are the assertions that the hint is read at
/// parse time rather than at construction (they are all built during the
/// restore, before anything is laid out), that a real layout is what fills it
/// in, and — the one that matters most — that it changes the cost and not the
/// content.
void main() {
  /// A pane's worth of colourised agent output, wide enough that parsing it at
  /// 80 columns wraps and reflowing it back unwraps.
  String history(int lines) => [
    for (var i = 0; i < lines; i++)
      '\x1b[38;5;${(i % 200) + 16}m*\x1b[0m \x1b[1mUpdate\x1b[0m('
          'lib/src/features/terminal/data/file_$i.dart)  '
          '\x1b[2m+${i % 40} -${i % 7}\x1b[0m  '
          '\x1b[38;5;${(i % 30) + 100}mand a tail long enough to wrap\x1b[0m',
  ].join('\r\n');

  /// [history] as the store holds it: encoded once out of a buffer the width a
  /// desktop pane really is.
  String stored(int lines, {int columns = 160}) {
    final source = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..resize(columns, 50)
      ..write('${history(lines)}\r\n');
    return encodeScrollback(source);
  }

  DormantTerminalInstance dormant(String text, {TerminalGridHint? hint}) =>
      DormantTerminalInstance(
        id: 'p1',
        title: 'claude',
        profileId: 'powershell',
        restoredScrollback: text,
        gridHint: hint,
      );

  group('the grid a restored pane parses at', () {
    test('is xterm\'s default when nothing has been laid out yet', () {
      final hint = TerminalGridHint();
      expect(hint.grid, isNull);

      expect(dormant(stored(40), hint: hint).terminal.viewWidth, 80);
    });

    test('is filled in by the pane the workbench does lay out', () {
      final hint = TerminalGridHint();
      final first = dormant(stored(40), hint: hint);

      // What `RenderTerminal` does once it knows the box it has.
      first.terminal.resize(163, 47);

      expect(hint.grid, (columns: 163, rows: 47));
    });

    test('is read when the buffer is built, not when the pane is made', () {
      // Every restored pane is constructed during the restore, long before
      // anything has been laid out — so a hint snapshotted at construction
      // would be null for all of them and buy nothing.
      final hint = TerminalGridHint();
      final second = dormant(stored(40), hint: hint);

      hint.grid = (columns: 163, rows: 47);

      expect(second.terminal.viewWidth, 163);
      expect(second.terminal.viewHeight, 47);
    });

    test('changes the cost and not the content', () {
      // The claim the whole change rests on. Parsing at 80 and reflowing to
      // 163 is what happens without a hint; parsing straight at 163 is what
      // happens with one. The user must not be able to tell which ran.
      final text = stored(300);
      final hinted = dormant(
        text,
        hint: TerminalGridHint()..grid = (columns: 163, rows: 47),
      ).terminal;
      final reflowed = dormant(text).terminal..resize(163, 47);

      expect(hinted.viewWidth, 163);
      expect(reflowed.viewWidth, 163);
      expect(hinted.mainBuffer.getText(), reflowed.mainBuffer.getText());
    });

    test('a pane with no hint at all still parses and shows its history', () {
      // The hint is optional: nothing outside the controller passes one.
      final pane = dormant(stored(40));
      expect(pane.terminal.mainBuffer.getText(), contains('file_39.dart'));
    });
  });

  group('through the workbench', () {
    /// A stored layout of [tabs] one-pane tabs, each holding [lines] of
    /// history.
    AppDatabase seeded({int tabs = 2, int lines = 200}) {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final text = stored(lines);
      TerminalLayoutDao(db).saveLayout([
        for (var i = 0; i < tabs; i++)
          StoredTerminalTab(
            id: 't$i',
            layout: PaneLayout.single('p$i'),
            focusedPaneId: 'p$i',
            panes: [
              StoredTerminalPane(
                id: 'p$i',
                tabId: 't$i',
                profileId: 'powershell',
                title: 'PowerShell',
                workingDirectory: r'C:\ws',
                scrollback: text,
              ),
            ],
          ),
      ], activeTabId: 't0');
      return db;
    }

    Future<TerminalSessionsController> launch(
      WidgetTester tester,
      AppDatabase db,
    ) async {
      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
        ),
      );
      await tester.pump();
      return container.read(terminalSessionsControllerProvider.notifier);
    }

    testWidgets('records the grid it drew a pane at', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1440, 900);
      final db = seeded();

      final controller = await launch(tester, db);
      final shown = controller.instanceFor('p0')! as DormantTerminalInstance;
      expect(
        shown.bufferBuilt,
        isTrue,
        reason: 'the active tab is on screen, so its history has been parsed',
      );
      // Any save carries it; this is the one a quit makes.
      controller.persistLayout();

      expect(TerminalLayoutDao(db).loadPaneGrid(), (
        columns: shown.terminal.viewWidth,
        rows: shown.terminal.viewHeight,
      ));
      expect(
        shown.terminal.viewWidth,
        greaterThan(80),
        reason:
            'nothing here proves anything unless the workbench draws a pane '
            'wider than the default an unhinted parse would use',
      );
    });

    testWidgets('the next launch parses into it, before anything is drawn', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1440, 900);
      final db = seeded();

      final first = await launch(tester, db);
      final drawn = (first.instanceFor('p0')! as DormantTerminalInstance)
          .terminal
          .viewWidth;
      first.persistLayout();

      // A second run over the same store. Its panes are built during the
      // restore, and the launch frame parses every mounted tab's history in
      // `build` — before the layout pass that measured `drawn` last time.
      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final second = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final pane = second.instanceFor('p1')! as DormantTerminalInstance;
      expect(
        pane.bufferBuilt,
        isFalse,
        reason: 'nothing has been laid out in this container at all',
      );

      expect(
        pane.terminal.viewWidth,
        drawn,
        reason:
            'the parse happened at 80 columns and will be reflowed to $drawn '
            'in the same frame — which is the cost this exists to remove',
      );
      expect(pane.terminal.mainBuffer.getText(), contains('file_199.dart'));
    });

    testWidgets('a store with no recorded grid simply has no hint', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1440, 900);
      final db = seeded();

      // Never saved, so nothing was recorded — a first run, or an upgrade.
      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final pane = controller.instanceFor('p1')! as DormantTerminalInstance;

      expect(pane.terminal.viewWidth, 80);
      expect(pane.terminal.mainBuffer.getText(), contains('file_199.dart'));
    });
  });
}
