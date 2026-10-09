import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';

import 'fake_instance.dart';

/// **On the desktop the Agent dashboard is always pinned** (round 81): the
/// first tab, past every close, back after a restart.
void main() {
  late TerminalLayoutStore db;
  setUp(() => db = TerminalLayoutStore.memory());
  tearDown(() => db.close());

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  List<String> tabIds(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      tab.id,
  ];

  String? pinnedOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider).pinnedTabId;

  test('pinning an empty workbench opens the dashboard, in front', () {
    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final controller = controllerOf(container);

    controller.pinDashboard();

    final pinned = pinnedOf(container);
    expect(pinned, isNotNull);
    expect(controller.tabIdOfPane(kOverviewPaneId), pinned);
    expect(tabIds(container), [pinned]);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      pinned,
    );
  });

  test('it goes first, behind the tab in front, and is not marked new', () {
    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    final shell = controller.openTab(TerminalProfile.powerShell);

    controller.pinDashboard();

    final state = container.read(terminalSessionsControllerProvider);
    expect(tabIds(container), [state.pinnedTabId, shell]);
    expect(state.activeTabId, shell);
    expect(state.unseenTabIds, isEmpty);
  });

  test('it cannot be closed, by itself or its pane', () {
    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final controller = controllerOf(container)..pinDashboard();
    final pinned = pinnedOf(container)!;

    controller.closeTab(pinned);
    controller.closePane(kOverviewPaneId);
    controller.closePanes([kOverviewPaneId]);

    expect(tabIds(container), [pinned]);
  });

  test('Close all and Close others leave it', () {
    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final controller = controllerOf(container)..pinDashboard();
    final pinned = pinnedOf(container)!;
    final a = controller.openTab(TerminalProfile.powerShell);
    final b = controller.openTab(TerminalProfile.commandPrompt);

    // Close others, from b.
    controller.closeTabs([pinned, a], activate: b);
    expect(tabIds(container), [pinned, b]);

    // Close all.
    controller.closeTabs(tabIds(container));
    expect(tabIds(container), [pinned]);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      pinned,
    );
  });

  test('closing its group moves it into the one that stays', () {
    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final controller = controllerOf(container)..pinDashboard();
    final pinned = pinnedOf(container)!;
    final pinnedGroup = controller.groupOfTab(pinned)!;
    controller.splitWorkspace(SplitAxis.horizontal);
    final other = controller.openTab(TerminalProfile.powerShell);

    expect(controller.closeGroup(pinnedGroup), isTrue);

    expect(tabIds(container), containsAll([pinned, other]));
    expect(
      controller.tabsInGroup(controller.groupOfTab(other)!).first.id,
      pinned,
    );
  });

  test('a restart brings it back, first, and still pinned', () {
    final first = fakeTerminalContainer(layoutStore: db);
    final controller = controllerOf(first)..pinDashboard();
    final shell = controller.openTab(TerminalProfile.powerShell);
    // Dragged out of first place before the quit.
    controller.reorderTab(controller.tabIdOfPane(kOverviewPaneId)!, 1);
    controller.persistLayout();
    first.dispose();

    final next = fakeTerminalContainer(
      layoutStore: db,
      restoreLivePanes: false,
    );
    addTearDown(next.dispose);
    final restored = controllerOf(next);
    expect(restored.tabIdOfPane(kOverviewPaneId), isNotNull);

    restored.pinDashboard();

    final pinned = pinnedOf(next);
    expect(pinned, restored.tabIdOfPane(kOverviewPaneId));
    expect(tabIds(next), [pinned, shell]);
    // One dashboard, not a second one beside the restored tab.
    expect(tabIds(next).where((id) => restored.isPinnedTab(id)), hasLength(1));
  });

  test('unpinned — the phone — the dashboard closes like any tab', () {
    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final controller = controllerOf(container);
    final dashboard = controller.openOverviewTab();

    expect(pinnedOf(container), isNull);
    controller.closeTab(dashboard);
    expect(tabIds(container), isEmpty);
  });
}
