import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_group_strip.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'pane_group_ui_test.dart'
    show activeTab, chipFor, controllerOf, pumpWorkbench, workbenchContainer;

/// Six panes stacked in half of a minimum window: more chips than the header
/// holds, and every pane still has to be reachable from it.
void main() {
  Future<(ProviderContainer, List<String>, String)> crowd(
    WidgetTester tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;
    final guests = <String>[];
    for (var i = 0; i < 5; i++) {
      controller.openTab(TerminalProfile.commandPrompt);
      guests.add(activeTab(container).layout.panes.single);
    }
    controller.activateTab(host);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );
    for (final guest in guests) {
      controller.movePaneIntoRegion(guest, left);
    }
    await pumpWorkbench(tester, container, size: const Size(720, 560));
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final group = activeTab(container).layout.groupOf(left)!;
    return (container, group.panes, left);
  }

  testWidgets('a crowded region header lists the panes it cannot show', (
    tester,
  ) async {
    final (container, panes, left) = await crowd(tester);
    final strip = tester.getRect(find.byType(PaneGroupStrip));
    final hidden = [
      for (final pane in panes)
        if (tester.getRect(chipFor(pane)).right > strip.right) pane,
    ];
    expect(hidden, isNotEmpty, reason: 'the fixture really is crowded');

    await tester.tap(find.byTooltip('Every pane in this region'));
    await tester.pumpAndSettle();
    // One row per pane, in the header's order.
    final rows = find.byWidgetPredicate((w) => w is PopupMenuItem<String>);
    expect(rows, findsNWidgets(panes.length));

    await tester.tap(rows.at(panes.indexOf(hidden.last)));
    await tester.pump();

    expect(
      activeTab(container).layout.groupOf(left)!.activePaneId,
      hidden.last,
    );
  });

  testWidgets('a plain mouse wheel scrolls a crowded header', (tester) async {
    final (_, panes, _) = await crowd(tester);
    final last = chipFor(panes.last);
    final before = tester.getRect(last).left;

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final strip = tester.getRect(find.byType(PaneGroupStrip));
    await tester.sendEventToBinding(
      pointer.hover(Offset(strip.center.dx, strip.center.dy)),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
    await tester.pump();

    expect(tester.getRect(last).left, lessThan(before));
  });
}
