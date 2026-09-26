import 'dart:convert';

import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala/src/features/terminal/application/terminal_layout_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Rearranging the tab strip by dragging a tab, which is what every browser,
/// every editor and every terminal does and this had no verb for at all: the
/// report was *"move to split panes, move to re-arrange tab — all should work
/// like normal applications"*, and *"click and drag should work as well"*.
///
/// So these drive a **mouse**, not a synthetic fling: pointer down, twenty
/// small moves, pointer up. A single `tester.drag` jump would pass over a strip
/// whose chips only start a drag after a long press, and pressing and holding
/// is exactly the thing a mouse user never does.

ProviderContainer harness() {
  final database = AppDatabase.memory();
  addTearDown(database.close);
  final container = fakeTerminalContainer(database: database);
  addTearDown(container.dispose);
  return container;
}

TerminalSessionsController controllerOf(ProviderContainer container) =>
    container.read(terminalSessionsControllerProvider.notifier);

List<String> tabOrder(ProviderContainer container) => [
  for (final tab in container.read(terminalSessionsControllerProvider).tabs)
    tab.id,
];

Future<void> pumpWorkbench(
  WidgetTester tester,
  ProviderContainer container, {
  Size window = const Size(1400, 900),
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: ShellShortcuts(child: WorkbenchView())),
      ),
    ),
  );
  await tester.pump();
}

/// Presses at [from] with a **mouse** and walks the pointer to [to] a step at a
/// time, leaving the button down. The caller finishes with [drop] or [cancel].
///
/// Stepped rather than jumped because the step is the whole question: a drag
/// that only ever arrives has never had to start, and starting is where a strip
/// that waits for a long press fails a mouse.
Future<TestGesture> dragFrom(
  WidgetTester tester,
  Offset from,
  Offset to,
) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  for (var step = 1; step <= 20; step++) {
    await gesture.moveTo(Offset.lerp(from, to, step / 20)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  return gesture;
}

/// What a pane's buffer holds, in bytes, without the grid it is drawn in.
///
/// `getText()` pads every row out to the terminal's width, and a pane moved
/// from one half of a split into a whole tab is legitimately a different width
/// — measured here as 80 bytes before the move and 78 after, for text that had
/// not changed at all. Trailing padding and blank rows are the grid's; the
/// characters are the buffer's.
int bufferBytes(TerminalInstance instance) => utf8
    .encode(
      instance.terminal.buffer
          .getText()
          .split('\n')
          .map((line) => line.trimRight())
          .where((line) => line.isNotEmpty)
          .join('\n'),
    )
    .length;

Future<void> drop(WidgetTester tester, TestGesture gesture) async {
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dragging a tab onto another one takes that place', (
    tester,
  ) async {
    final container = harness();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);
    final third = controller.openTab(TerminalProfile.powerShell);
    await pumpWorkbench(tester, container);
    expect(tabOrder(container), [first, second, third]);

    final chips = find.byType(TerminalTabChip);
    final gesture = await dragFrom(
      tester,
      tester.getCenter(chips.at(2)),
      tester.getCenter(chips.at(0)),
    );
    await drop(tester, gesture);

    expect(tabOrder(container), [
      third,
      first,
      second,
    ], reason: 'the tab took the place it was dropped on');
  });

  testWidgets('and dragging one onto the room after the last tab sends it '
      'to the end', (tester) async {
    final container = harness();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);
    final third = controller.openTab(TerminalProfile.powerShell);
    await pumpWorkbench(tester, container);

    final gesture = await dragFrom(
      tester,
      tester.getCenter(find.byType(TerminalTabChip).at(0)),
      tester.getCenter(find.byKey(kTabStripEmptySpace)),
    );
    await drop(tester, gesture);

    expect(tabOrder(container), [second, third, first]);
  });

  testWidgets('the strip says where the tab will land before it is dropped', (
    tester,
  ) async {
    final container = harness();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    await pumpWorkbench(tester, container);
    expect(
      find.byKey(kTabDropMarker),
      findsNothing,
      reason: 'nothing is being dragged',
    );

    final chips = find.byType(TerminalTabChip);
    final target = tester.getRect(chips.at(0));
    final gesture = await dragFrom(
      tester,
      tester.getCenter(chips.at(1)),
      target.center,
    );

    expect(find.byKey(kTabDropMarker), findsOneWidget);
    expect(
      tester.getRect(find.byKey(kTabDropMarker)).left,
      closeTo(target.left, 1),
      reason: 'a tab coming from the right lands before the one it is over',
    );

    await drop(tester, gesture);
    expect(
      find.byKey(kTabDropMarker),
      findsNothing,
      reason: 'the mark goes with the drag',
    );
  });

  testWidgets('and it still rearranges a strip narrow enough to scroll', (
    tester,
  ) async {
    // The other end of the window matrix. An overflowing rail has no room
    // after the last tab by definition — [kTabStripEmptySpace] is not built at
    // all — so the chips are the whole of the gesture there, and they still
    // have to be.
    final container = harness();
    final controller = controllerOf(container);
    for (var i = 0; i < 10; i++) {
      controller.openTab(TerminalProfile.powerShell);
    }
    await pumpWorkbench(tester, container, window: const Size(700, 600));
    expect(
      find.byKey(kTabStripEmptySpace),
      findsNothing,
      reason: 'ten tabs in a 700px window do not fit',
    );
    final before = tabOrder(container);
    // A scrolling rail only builds the chips it can show, and the tenth tab is
    // the active one — so the strip is scrolled to the far end and the first
    // chip in the tree is not the first tab. Go back to the start, and it is.
    controller.activateTab(before.first);
    await tester.pumpAndSettle();

    final chips = find.byType(TerminalTabChip);
    final gesture = await dragFrom(
      tester,
      tester.getCenter(chips.at(1)),
      tester.getCenter(chips.at(0)),
    );
    await drop(tester, gesture);

    expect(tabOrder(container).take(2), [before[1], before[0]]);
  });

  testWidgets('releasing away from the strip leaves the order alone', (
    tester,
  ) async {
    final container = harness();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    await pumpWorkbench(tester, container);
    final before = tabOrder(container);

    final gesture = await dragFrom(
      tester,
      tester.getCenter(find.byType(TerminalTabChip).at(1)),
      const Offset(700, 600),
    );
    await drop(tester, gesture);

    expect(
      tabOrder(container),
      before,
      reason: 'a cancelled drag moves nothing',
    );
    expect(
      container.read(terminalSessionsControllerProvider).tabs,
      hasLength(2),
      reason: 'and loses nothing',
    );
  });

  testWidgets('a tab dropped on a pane makes a group beside it', (
    tester,
  ) async {
    // The verb that already existed, driven the way a mouse drives it rather
    // than with one synthetic jump — reordering must not have taken the drop
    // that divides the workspace away from it.
    //
    // Where it lands changed twice. It is the pane itself rather than a header
    // the region no longer draws, and the tab now arrives in a **workspace
    // group** of its own rather than as a bare region: a tab carries a session,
    // a view and a status strip together, and only a group hosts that. What has
    // not changed is the point of the gesture — the session it carried keeps
    // running, mid-command and all.
    final container = harness();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final left = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    final guestInstance = controller.instanceFor(guestPane);
    controller.activateTab(host);

    await pumpWorkbench(tester, container);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );
    await tester.pump();

    final leftPane = find.byWidgetPredicate(
      (widget) => widget is TerminalPaneView && widget.instance.id == left,
    );
    final target = tester.getRect(leftPane);
    final gesture = await dragFrom(
      tester,
      tester.getCenter(find.byType(TerminalTabChip).at(1)),
      Offset(target.left + target.width * 0.9, target.center.dy),
    );
    await drop(tester, gesture);

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2), reason: 'it is still a tab');
    expect(
      state.workspace!.groups,
      hasLength(2),
      reason: 'the workspace divided, so the tab has a strip and a bar',
    );
    // The tab it was dropped on kept its own two panes; nothing about it moved.
    final hostTab = state.tabs.firstWhere((tab) => tab.layout.contains(left));
    expect(hostTab.layout.panes, hasLength(2));
    expect(hostTab.id, host);
    expect(
      controller.instanceFor(guestPane),
      same(guestInstance),
      reason: 'the session moved rather than being closed and relaunched',
    );
  });

  testWidgets('a pane still drags out of a region onto the strip', (
    tester,
  ) async {
    // The grip moved — a region of a split draws no header now, so the handle
    // is the one floating on the pane — and the gesture did not.
    final container = harness();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    await pumpWorkbench(tester, container);
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();

    final gesture = await dragFrom(
      tester,
      tester.getCenter(find.byKey(paneDragHandleKey(right))),
      tester.getCenter(find.byKey(kTabStripEmptySpace)),
    );
    await drop(tester, gesture);

    expect(
      container.read(terminalSessionsControllerProvider).tabs,
      hasLength(2),
      reason: 'the drop that makes a pane a tab is still the strip\'s',
    );
  });

  testWidgets('a pane dropped on a tab chip moves into that tab', (
    tester,
  ) async {
    // The counterpart of the drop above. Tabs already moved between split
    // regions; a *pane* could only ever leave its region for the strip, where
    // it became a tab of its own — there was no way to say "put this pane in
    // that tab", because the workbench shows one tab's regions at a time and a
    // background tab has nothing on screen to drop onto except its chip.
    //
    // Nothing about the pane is rebuilt: the controller moves an id between two
    // layouts and never touches the instance map, so the assertions below are
    // the instance's own identity and the bytes already in its buffer.
    final container = harness();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);
    await pumpWorkbench(tester, container);

    // Two panes in the second tab, so moving one leaves a tab behind rather
    // than testing tab closure by accident.
    final guest = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    )!;
    await tester.pump();

    final instance = controller.instanceFor(guest)!;
    (instance as FakeTerminalInstance).receive('half a command already typed');
    await tester.pump();
    final bytesBefore = bufferBytes(instance);
    expect(bytesBefore, greaterThan(0), reason: 'the buffer holds something');

    final gesture = await dragFrom(
      tester,
      tester.getCenter(find.byKey(paneDragHandleKey(guest))),
      tester.getCenter(find.byType(TerminalTabChip).first),
    );
    // The chip says what the drop will do before the button comes up.
    await tester.pump();
    expect(find.byKey(kPaneJoinMarker), findsOneWidget);
    await drop(tester, gesture);

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2), reason: 'no tab was made or lost');
    expect(
      state.tabs.firstWhere((tab) => tab.id == host).layout.panes,
      contains(guest),
      reason: 'the pane is in the tab whose chip took the drop',
    );
    expect(
      state.tabs.firstWhere((tab) => tab.id == second).layout.panes,
      isNot(contains(guest)),
      reason: 'and out of the one it came from',
    );
    expect(
      controller.instanceFor(guest),
      same(instance),
      reason: 'the same object at a new address — nothing was relaunched',
    );
    expect(
      bufferBytes(instance),
      bytesBefore,
      reason: 'and it kept every byte it had already received',
    );

    // The same persistence a tab move gets: the row is re-parented, not
    // rewritten, and it is written by the move rather than by a later save.
    final stored = container.read(terminalLayoutDaoProvider).loadLayout();
    final row = stored.tabs
        .expand((tab) => tab.panes)
        .firstWhere((pane) => pane.id == guest);
    expect(row.tabId, host);
  });
}
