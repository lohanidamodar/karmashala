import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/instances.dart';

import 'fake_instance.dart';

/// What the panes are holding, for the memory census the log prints.
///
/// The numbers are diagnostics, so what matters is that they are true *and*
/// that taking them changes nothing. The sharp one is the last test: a
/// restored pane parses its stored scrollback the first time anything reads
/// its `terminal`, so a census written the obvious way would pay that parse
/// for every never-opened pane on every tick — the measurement becoming the
/// cost it was added to find.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late TerminalSessionsController controller;

  setUp(() {
    WidgetsFlutterBinding.ensureInitialized();
    db = AppDatabase.memory();
    container = fakeTerminalContainer(database: db);
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  test('a fresh layout counts its panes and their rows', () {
    controller.openTab(TerminalProfile.powerShell);
    final second = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;

    final before = controller.paneFootprint;
    expect(before.live, 2);
    expect(before.detached, 0);
    expect(before.unparsedPanes, 0);
    expect(before.rows, greaterThan(0));

    controller
        .instanceFor(second)!
        .terminal
        .write(List.filled(200, 'a line of output').join('\r\n'));

    // Rows are the term that grows with *use*: the pane count did not move.
    final after = controller.paneFootprint;
    expect(after.live, 2);
    expect(after.rows, greaterThan(before.rows));
  });

  test('text held for the autosave is counted beside the rows', () {
    controller.openTab(TerminalProfile.powerShell);
    expect(controller.paneFootprint.heldChars, 0);

    controller
        .instanceFor(controller.state.tabs.single.focusedPaneId)!
        .terminal
        .write('something worth saving\r\n');
    controller.saveDirtyScrollback();

    // The encoding is a second copy of the history, and it is the one the
    // census can see without touching a buffer.
    expect(controller.paneFootprint.heldChars, greaterThan(0));
  });

  test('a restored pane is counted without its scrollback being parsed', () {
    controller.openTab(TerminalProfile.powerShell);
    controller
        .instanceFor(controller.state.tabs.single.focusedPaneId)!
        .terminal
        .write('hello from the past\r\n');
    controller.persistLayout();
    container.dispose();

    final next = fakeTerminalContainer(database: db, restoreLivePanes: false);
    addTearDown(next.dispose);
    final restored = next.read(terminalSessionsControllerProvider.notifier);
    final paneId = next
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .layout
        .panes
        .single;
    final pane = restored.instanceFor(paneId)! as DormantTerminalInstance;
    expect(pane.bufferBuilt, isFalse);

    final footprint = restored.paneFootprint;

    // The pane is reported, its history is reported as text, and nothing was
    // built to say so. Remove the `bufferBuilt` guard in `paneFootprint` and
    // this is the line that fails.
    expect(pane.bufferBuilt, isFalse);
    expect(footprint.live, 1);
    expect(footprint.unparsedPanes, 1);
    expect(footprint.rows, 0);
    expect(footprint.heldChars, greaterThan(0));

    // And once something does ask to see it, the rows appear and the pane
    // stops being counted as unparsed — so the two terms cannot both go blind.
    pane.terminal;
    final shown = restored.paneFootprint;
    expect(shown.unparsedPanes, 0);
    expect(shown.rows, greaterThan(0));
  });
}
