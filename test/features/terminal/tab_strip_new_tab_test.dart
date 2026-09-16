import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Double-clicking the empty part of a tab bar opens a new tab in VS Code,
/// every browser and most terminals. The owner asked for it here.
///
/// The risk the gesture carries is entirely in *where* it lives. A detector
/// wrapped around the rail would join the arena for every pointer that lands on
/// a chip: a double-click on a tab would open a new one rather than activating
/// it, and every single click on a tab would sit out the 300 ms double-tap
/// window first. So the three cases below are the gesture, the chip it must not
/// touch, and the drop target it must not swallow.

ProviderContainer harness() {
  final database = AppDatabase.memory();
  addTearDown(database.close);
  final container = fakeTerminalContainer(database: database);
  addTearDown(container.dispose);
  return container;
}

TerminalSessionsController controllerOf(ProviderContainer container) =>
    container.read(terminalSessionsControllerProvider.notifier);

int tabCount(ProviderContainer container) =>
    container.read(terminalSessionsControllerProvider).tabs.length;

Future<void> pumpWorkbench(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.physicalSize = const Size(1400, 900);
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

/// Two taps inside the double-tap window. `flutter_test` has no `doubleTap`, so
/// the gap is spelled out — and it is the same gap the recogniser uses.
Future<void> doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('double-clicking the empty strip opens a terminal', (
    tester,
  ) async {
    final container = harness();
    controllerOf(container).openTab(TerminalProfile.powerShell);
    await pumpWorkbench(tester, container);
    expect(tabCount(container), 1);

    // Where the target is, before what it does. It starts where the last chip
    // ends and runs to the end of the rail, which is now the end of the strip:
    // the toolbar that used to sit beside it moved to the title bar when every
    // workspace group got a strip of its own.
    final empty = tester.getRect(find.byKey(kTabStripEmptySpace));
    expect(
      empty.left,
      greaterThanOrEqualTo(tester.getRect(find.byType(TerminalTabChip)).right),
    );
    expect(find.byType(TerminalToolbar), findsNothing);

    await doubleTap(tester, find.byKey(kTabStripEmptySpace));

    expect(tabCount(container), 2);
    expect(find.byType(TerminalTabChip), findsNWidgets(2));
  });

  testWidgets('and only the empty part of it: a chip is still a chip', (
    tester,
  ) async {
    final container = harness();
    final first = controllerOf(container).openTab(TerminalProfile.powerShell);
    controllerOf(container).openTab(TerminalProfile.commandPrompt);
    await pumpWorkbench(tester, container);
    expect(container.read(terminalSessionsControllerProvider).activeTabId,
        isNot(first));

    // A single click activates *now*. If the gesture had been wrapped around
    // the rail this would still pass a frame later — after the 300 ms
    // double-tap window closed — and the strip would feel broken with nothing
    // failing.
    await tester.tap(find.byType(TerminalTabChip).first);
    await tester.pump();
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      first,
    );

    // And a double click on a chip is two activations of that chip, which is
    // what it has always been. It is emphatically not a new tab.
    await doubleTap(tester, find.byType(TerminalTabChip).first);

    expect(tabCount(container), 2);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      first,
    );
  });

  testWidgets('the strip still takes a pane dropped on its empty space', (
    tester,
  ) async {
    // The other thing an overlay can quietly break. The `DragTarget` wrapping
    // the strip is an ancestor of the new detector, so it stays on the hit-test
    // path — this is what says so rather than assuming it.
    final container = harness();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    await pumpWorkbench(tester, container);
    final second = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();
    expect(tabCount(container), 1);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(paneDragHandleKey(second))),
    );
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byKey(kTabStripEmptySpace)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tabCount(container), 2, reason: 'the drop still makes a tab');
  });
}
