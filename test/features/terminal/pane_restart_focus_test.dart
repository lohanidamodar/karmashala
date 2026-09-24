import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// A pane that comes back must come back **typable, and showing its prompt**.
///
/// The owner: *"after resume sometimes i'm unable to focus to the claude
/// prompt, it should be auto focused on the active tab. and always scroll to
/// the prompt"*.
///
/// Both halves of that turned out to be one fault, and it is not in the focus
/// code. `TerminalSessionsController.startPane` swaps the pane's whole instance
/// — a new `Terminal`, a new `FocusNode`, a new `ScrollController` — but
/// `TerminalPaneStack` watches only [terminalTabsProvider] and
/// [terminalActiveTabIdProvider], and a restart moves neither. So the stack did
/// not rebuild, the pane went on rendering the instance that had just been
/// *disposed*, and the new focus node was never attached to anything.
/// `FocusNode.requestFocus()` on an unattached node is a silent no-op, and the
/// buffer on screen was the dead session's — which is why there was no prompt
/// to scroll to either.
///
/// "Sometimes" was any unrelated rebuild of the stack picking the swap up in
/// passing. See [terminalPaneInstanceProvider] for the fix and the measurement.
void main() {
  ProviderContainer panelContainer({AppDatabase? database}) {
    final db = database ?? AppDatabase.memory();
    if (database == null) addTearDown(db.close);
    final container = fakeTerminalContainer(database: db);
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

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  String solePaneOf(ProviderContainer container, String tabId) => container
      .read(terminalSessionsControllerProvider)
      .tabs
      .firstWhere((t) => t.id == tabId)
      .layout
      .panes
      .single;

  /// The view the panel actually has on screen.
  ///
  /// Its `focusNode` and `scrollController` are the witnesses that answer "is
  /// the thing on screen the session that was just started, or the one that was
  /// just disposed?". Deliberately **not** its `terminal`: a pane whose process
  /// exited hands its buffer to its replacement rather than re-encoding it (see
  /// `resume_cost_test.dart`), so on that path both instances share one
  /// `Terminal` and it cannot tell them apart. The focus node and the scroll
  /// controller are minted per instance and never handed over, which is exactly
  /// why they were the two things the stale view got wrong.
  TerminalView viewOnScreen(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView));

  testWidgets('a restarted pane takes the keyboard', (tester) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    final tab = controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);
    final paneId = solePaneOf(container, tab);

    final died = controller.instanceFor(paneId)! as FakeTerminalInstance;
    expect(died.focusNode.hasFocus, isTrue, reason: 'it had the keyboard');
    died.exitWith(1);
    await tester.pump();

    // The Start button's path, and the one `_restoreLivePanesIn` takes.
    controller.startPane(paneId);
    await tester.pump();

    final restarted = controller.instanceFor(paneId)!;
    expect(
      identical(restarted, died),
      isFalse,
      reason:
          'starting a pane replaces its instance; that is the whole problem',
    );
    expect(
      restarted.focusNode.hasFocus,
      isTrue,
      reason: 'the pane that just came back is the one you can type into',
    );
    // The direct statement of the fault: a node with no context has never been
    // attached to a widget, and asking it for focus can only ever be a no-op.
    expect(restarted.focusNode.context, isNotNull);
  });

  testWidgets('a restarted pane is the one on screen, scrolled to its prompt', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    final tab = controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);
    final paneId = solePaneOf(container, tab);

    final died = controller.instanceFor(paneId)! as FakeTerminalInstance;
    for (var i = 0; i < 300; i++) {
      died.receive('claude said $i\r\n');
    }
    await tester.pump();
    // Read back through the log, the way anybody reads an agent's output, so
    // the view being reused rather than rebuilt is visible as a stale offset
    // and not only as a stale buffer.
    died.scrollController.jumpTo(0);
    await tester.pump();
    died.exitWith(1);
    await tester.pump();

    controller.startPane(paneId);
    await tester.pump();

    final restarted = controller.instanceFor(paneId)! as FakeTerminalInstance;
    expect(
      viewOnScreen(tester).scrollController,
      same(restarted.scrollController),
      reason: 'the view drawn belongs to the new session, not the disposed one',
    );
    // The restarted view is a fresh one, so `RenderTerminal` is back to its
    // initial stick-to-bottom and its first layout corrects there — which is
    // the whole of "scroll to the prompt", and why no explicit scroll call is
    // needed once the pane is rebuilt at all. Asserted through the new pane's
    // own controller: before the fix this line did not fail an expectation, it
    // *threw* — `ScrollController not attached to any scroll views`, because
    // nothing on screen had ever been attached to it.
    final position = restarted.scrollController.position;
    expect(position.pixels, position.maxScrollExtent);

    // ...and it keeps following, so the prompt the new process prints is in
    // view rather than somewhere below the fold.
    restarted.receive('\r\n> ');
    await tester.pump();
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('a layout restored with a Start on it comes back typable', (
    tester,
  ) async {
    // The end-to-end shape of the report, and the one path a tab switch does
    // not accidentally repair. Every pane a launch declines arrives exactly
    // like this — an agent pane, a pane whose process had already exited, any
    // pane at all with the setting off — and the user presses Start on the tab
    // they are already looking at. No tab changes, so `terminalTabsProvider`
    // and `terminalActiveTabIdProvider` both hand back what they handed back
    // before, and before the fix the panel had no reason to rebuild at all.
    //
    // Restore-on-activate, by contrast, was never broken: activating a tab
    // moves `activeTabId`, and that rebuild picks the swapped instance up on
    // the way past. Pinned here so the difference is on the record.
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final first = fakeTerminalContainer(database: db);
    final firstController = first.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tab = firstController.openTab(TerminalProfile.powerShell);
    final paneId = first
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == tab)
        .layout
        .panes
        .single;
    for (var i = 0; i < 300; i++) {
      firstController.instanceFor(paneId)!.terminal.write('claude said $i\r\n');
    }
    firstController.persistLayout();
    first.dispose();

    final container = fakeTerminalContainer(
      database: db,
      restoreLivePanes: false,
    );
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    await pumpPanel(tester, container);
    expect(
      container.read(terminalSessionsControllerProvider).livenessOf(paneId),
      PaneLiveness.restored,
      reason: 'a record with a Start button on it, which is the state reported',
    );

    controller.startPane(paneId);
    await tester.pump();

    final restarted = controller.instanceFor(paneId)!;
    expect(
      container.read(terminalSessionsControllerProvider).livenessOf(paneId),
      PaneLiveness.live,
    );
    expect(restarted.focusNode.hasFocus, isTrue);
    // A dormant pane replays its history into a *new* buffer rather than
    // handing one over, so here the terminal on screen is a witness of its own.
    expect(viewOnScreen(tester).focusNode, same(restarted.focusNode));
    expect(viewOnScreen(tester).terminal, same(restarted.terminal));
    // The Start bar gone, the pane is taller; that size settles like any other.
    await tester.pump(kColumnResizeSettle);
  });

  testWidgets('a restart still refuses to take the keyboard from a text field', (
    tester,
  ) async {
    // The rule `_focusActivePane` has always applied, now that the restart path
    // can actually take focus at all: nothing about a pane coming back is worth
    // pulling the keyboard out of quick open, a search bar or a composer.
    final container = panelContainer();
    final controller = controllerOf(container);
    final tab = controller.openTab(TerminalProfile.powerShell);
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: TextField(focusNode: field)),
                const Expanded(child: WorkbenchView()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final paneId = solePaneOf(container, tab);
    field.requestFocus();
    await tester.pump();
    expect(field.hasFocus, isTrue);

    (controller.instanceFor(paneId)! as FakeTerminalInstance).exitWith(1);
    await tester.pump();
    controller.startPane(paneId);
    await tester.pump();

    expect(
      field.hasFocus,
      isTrue,
      reason: 'the user is typing; a pane coming back does not interrupt them',
    );
    expect(controller.instanceFor(paneId)!.focusNode.hasFocus, isFalse);
  });
}
