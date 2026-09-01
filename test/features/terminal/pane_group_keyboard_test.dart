import 'package:karmashala/src/app/shell/tab_picker.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/empty_pane_region.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_group_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Everything the region headers can be dragged to do, done from the keyboard.
///
/// A drag is a mouse gesture, and a feature that only has one is a feature some
/// people cannot use at all. The picker sources tested here are what the
/// command palette hands to [TabPicker], so each drag has an equal that is
/// typed rather than swept.
void main() {
  late ProviderContainer container;
  late TerminalSessionsController controller;

  setUp(() {
    container = fakeTerminalContainer();
    addTearDown(container.dispose);
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  TerminalTab activeTab() =>
      container.read(terminalSessionsControllerProvider).activeTab!;

  /// Runs [read] inside a widget, which is the only place a `WidgetRef` exists.
  Future<T> withRef<T>(WidgetTester tester, T Function(WidgetRef ref) read) async {
    late T result;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            result = read(ref);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  testWidgets('a tab can be moved into an occupied region without a drag', (
    tester,
  ) async {
    final host = controller.openTab(TerminalProfile.powerShell);
    final left = activeTab().layout.panes.single;
    controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab().layout.panes.single;
    controller.activateTab(host);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );

    final entries = await withRef(tester, (ref) => tabsMovableInto(ref, left));

    expect(entries, hasLength(1), reason: 'the guest, not the host itself');
    entries.single.item.onSelect();
    await tester.pump();

    expect(container.read(terminalSessionsControllerProvider).tabs, hasLength(1));
    expect(activeTab().layout.groupOf(left)!.panes, [left, guestPane]);
  });

  testWidgets('a pane can be moved to another region without a drag', (
    tester,
  ) async {
    controller.openTab(TerminalProfile.powerShell);
    final left = activeTab().layout.panes.single;
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    final third = controller.openInSlot(
      controller.splitPane(SplitAxis.vertical)!,
      TerminalProfile.powerShell,
    )!;

    final entries = await withRef(
      tester,
      (ref) => regionsMovableTo(ref, third),
    );

    expect(
      entries.map((e) => e.item.title),
      contains('A new tab'),
      reason: 'the way back out of the split belongs in the same list',
    );
    expect(
      entries,
      hasLength(3),
      reason: 'the two other regions, and a tab of its own',
    );

    entries.first.item.onSelect();
    await tester.pump();

    final layout = activeTab().layout;
    expect(layout.groups, hasLength(2));
    expect(layout.groupOf(left)!.panes, [left, third]);
    expect(layout.groupOf(right)!.panes, [right]);
  });

  testWidgets('the last entry takes the pane out to a tab of its own', (
    tester,
  ) async {
    controller.openTab(TerminalProfile.powerShell);
    final left = activeTab().layout.panes.single;
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;

    final entries = await withRef(
      tester,
      (ref) => regionsMovableTo(ref, right),
    );
    entries.last.item.onSelect();
    await tester.pump();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2));
    expect(state.activeTab!.layout.panes, [right]);
    expect(
      state.tabs.firstWhere((t) => t.id != state.activeTabId).layout.panes,
      [left],
    );
  });

  test('a pane with nowhere to go offers nothing', () {
    controller.openTab(TerminalProfile.powerShell);
    final only = activeTab().layout.panes.single;
    expect(controller.regionAnchorsBesides(only), isEmpty);
  });

  test('the panes stacked in a region can be cycled', () {
    final host = controller.openTab(TerminalProfile.powerShell);
    final first = activeTab().layout.panes.single;
    final guest = controller.openTab(TerminalProfile.commandPrompt);
    final second = activeTab().layout.panes.single;
    controller.activateTab(host);
    controller.moveTabIntoSlot(guest, first);
    expect(activeTab().focusedPaneId, second);

    controller.nextPaneInRegion();
    expect(activeTab().focusedPaneId, first);
    expect(activeTab().layout.groups.single.activePaneId, first);

    controller.nextPaneInRegion();
    expect(activeTab().focusedPaneId, second, reason: 'it wraps');

    controller.previousPaneInRegion();
    expect(activeTab().focusedPaneId, first);
  });

  test('cycling a region holding one pane does nothing', () {
    controller.openTab(TerminalProfile.powerShell);
    final only = activeTab().layout.panes.single;
    controller.nextPaneInRegion();
    expect(activeTab().focusedPaneId, only);
  });
}
