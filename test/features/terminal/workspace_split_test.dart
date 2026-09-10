import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'fake_instance.dart';

/// The unit of splitting is the whole middle workspace, not the terminal area
/// inside one tab. The report: *"every split pane should have it's tabbar and
/// its statusbar ... not like only split the terminal space"*.
///
/// So the window holds a tree of **groups**, each with its own strip of tabs,
/// and these are the rules that tree keeps.
void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: fakeTerminalOverrides());
    addTearDown(container.dispose);
    return container;
  }

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  TerminalSessionsState stateOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider);

  group('one group until something splits it', () {
    test('every tab opens into the same group', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final second = controller.openTab(TerminalProfile.powerShell);

      final state = stateOf(container);
      expect(state.workspace!.groups, hasLength(1));
      expect(state.workspace!.groups.single.panes, hasLength(2));
      expect(state.focusedGroupId, state.workspace!.groups.single.id);
      expect(state.activeTabId, second);
    });

    test('closing the last tab leaves no workspace at all', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final tab = controller.openTab(TerminalProfile.powerShell);
      controller.closeTab(tab);

      expect(stateOf(container).workspace, isNull);
      expect(stateOf(container).focusedGroupId, isNull);
    });
  });

  group('splitting the workspace', () {
    test('makes a second group, empty, with the keyboard in it', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);

      final groupId = controller.splitWorkspace(SplitAxis.horizontal);

      final state = stateOf(container);
      expect(state.workspace!.groups, hasLength(2));
      expect(state.focusedGroupId, groupId);
      expect(controller.isEmptyGroup(groupId!), isTrue);
      expect(
        state.activeTabId,
        isNull,
        reason: 'an empty group has no tab to be typing into',
      );
      expect(state.tabs, hasLength(1), reason: 'a split starts nothing');
    });

    test('the new group takes the next tab that is opened', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final first = controller.openTab(TerminalProfile.powerShell);
      final groupId = controller.splitWorkspace(SplitAxis.horizontal)!;

      final second = controller.openTab(TerminalProfile.powerShell);

      final state = stateOf(container);
      expect(controller.isEmptyGroup(groupId), isFalse);
      expect(
        controller.tabsInGroup(groupId).map((tab) => tab.id),
        [second],
      );
      expect(state.activeTabId, second);
      final other = state.workspace!.groups
          .firstWhere((group) => group.id != groupId);
      expect(other.panes, [first]);
    });

    test('an empty group cannot itself be split', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      controller.splitWorkspace(SplitAxis.horizontal);

      expect(controller.splitWorkspace(SplitAxis.vertical), isNull);
      expect(stateOf(container).workspace!.groups, hasLength(2));
    });

    test('the empty room carries an id nothing can mistake for a tab', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      controller.splitWorkspace(SplitAxis.horizontal);

      final empty = stateOf(container).workspace!.groups.firstWhere(
        (group) => controller.isEmptyGroup(group.id),
      );
      expect(isEmptyGroupSlot(empty.panes.single), isTrue);
    });
  });

  group('tabs move between groups', () {
    test('a tab dropped on another group joins its strip and shows there', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final first = controller.openTab(TerminalProfile.powerShell);
      final second = controller.openTab(TerminalProfile.powerShell);
      final target = controller.splitWorkspace(SplitAxis.horizontal)!;

      expect(controller.moveTabToGroup(second, target), isTrue);

      expect(controller.tabsInGroup(target).map((tab) => tab.id), [second]);
      expect(stateOf(container).activeTabId, second);
      final origin = stateOf(container).workspace!.groups
          .firstWhere((group) => group.id != target);
      expect(origin.panes, [first]);
    });

    test('a group that loses its last tab collapses', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final only = controller.openTab(TerminalProfile.powerShell);
      final target = controller.splitWorkspace(SplitAxis.horizontal)!;

      controller.moveTabToGroup(only, target);

      final state = stateOf(container);
      expect(state.workspace!.groups, hasLength(1));
      expect(state.workspace!.groups.single.panes, [only]);
      expect(state.activeTabId, only);
    });

    test('a tab already in the group is refused', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final tab = controller.openTab(TerminalProfile.powerShell);
      final groupId = stateOf(container).focusedGroupId!;

      expect(controller.canMoveTabToGroup(tab, groupId), isFalse);
      expect(controller.moveTabToGroup(tab, groupId), isFalse);
    });

    test('closing a tab keeps the keyboard in the group it was in', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final left = controller.openTab(TerminalProfile.powerShell);
      final target = controller.splitWorkspace(SplitAxis.horizontal)!;
      final rightA = controller.openTab(TerminalProfile.powerShell);
      final rightB = controller.openTab(TerminalProfile.powerShell);
      expect(controller.tabsInGroup(target).map((tab) => tab.id), [
        rightA,
        rightB,
      ]);

      controller.closeTab(rightB);

      final state = stateOf(container);
      expect(state.focusedGroupId, target);
      expect(
        state.activeTabId,
        rightA,
        reason: 'not the other group\'s tab just because it is last',
      );
      expect(state.tabs.map((tab) => tab.id), containsAll([left, rightA]));
    });
  });

  group('a tab dropped on an edge makes a group, never a bare region', () {
    test('the tab lands in a new group beside the one it was dropped on', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final host = controller.openTab(TerminalProfile.powerShell);
      final dropped = controller.openTab(TerminalProfile.powerShell);
      final hostGroup = stateOf(container).focusedGroupId!;

      expect(
        controller.moveTabBesideGroup(dropped, hostGroup, SplitAxis.vertical),
        isTrue,
      );

      final state = stateOf(container);
      expect(state.workspace!.groups, hasLength(2));
      expect(controller.tabsInGroup(hostGroup).map((tab) => tab.id), [host]);
      final made = state.workspace!.groups
          .firstWhere((group) => group.id != hostGroup);
      expect(made.panes, [dropped]);
      expect(state.activeTabId, dropped);
      // The tab it divided is untouched: a *tab* split is not a pane split.
      expect(
        state.tabs.firstWhere((tab) => tab.id == host).layout.panes,
        hasLength(1),
      );
    });

    test('insertBefore puts the new group on the leading side', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final host = controller.openTab(TerminalProfile.powerShell);
      final dropped = controller.openTab(TerminalProfile.powerShell);
      final hostGroup = stateOf(container).focusedGroupId!;

      controller.moveTabBesideGroup(
        dropped,
        hostGroup,
        SplitAxis.horizontal,
        insertBefore: true,
      );

      expect(stateOf(container).workspace!.panes, [dropped, host]);
    });

    test('the only tab of a group cannot be dropped beside itself', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final only = controller.openTab(TerminalProfile.powerShell);
      final groupId = stateOf(container).focusedGroupId!;

      expect(controller.canMoveTabBesideGroup(only, groupId), isFalse);
      expect(
        controller.moveTabBesideGroup(only, groupId, SplitAxis.horizontal),
        isFalse,
      );
      expect(stateOf(container).workspace!.groups, hasLength(1));
    });
  });

  group('focus', () {
    test('moves to the group next door and takes the active tab with it', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final left = controller.openTab(TerminalProfile.powerShell);
      final right = controller.splitWorkspace(SplitAxis.horizontal)!;
      final moved = controller.openTab(TerminalProfile.powerShell);
      expect(stateOf(container).activeTabId, moved);

      expect(controller.moveGroupFocus(PaneDirection.left), isTrue);

      expect(stateOf(container).activeTabId, left);
      expect(stateOf(container).focusedGroupId, isNot(right));

      expect(controller.moveGroupFocus(PaneDirection.right), isTrue);
      expect(stateOf(container).activeTabId, moved);
    });

    test('stops at the edge', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);

      expect(controller.moveGroupFocus(PaneDirection.right), isFalse);
    });
  });

  group('closing a group', () {
    test('takes its tabs with it and collapses the split', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final kept = controller.openTab(TerminalProfile.powerShell);
      final target = controller.splitWorkspace(SplitAxis.horizontal)!;
      controller.openTab(TerminalProfile.powerShell);

      expect(controller.closeGroup(target), isTrue);

      final state = stateOf(container);
      expect(state.workspace!.groups, hasLength(1));
      expect(state.tabs.map((tab) => tab.id), [kept]);
      expect(state.activeTabId, kept);
    });

    test('an empty group closes without touching any tab', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final kept = controller.openTab(TerminalProfile.powerShell);
      final target = controller.splitWorkspace(SplitAxis.horizontal)!;

      expect(controller.closeGroup(target), isTrue);

      final state = stateOf(container);
      expect(state.workspace!.groups, hasLength(1));
      expect(state.tabs.map((tab) => tab.id), [kept]);
      expect(state.activeTabId, kept);
    });

    test('the only group there is stays', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);

      expect(controller.closeGroup(stateOf(container).focusedGroupId!), isFalse);
    });
  });

  group('order along a strip', () {
    test('a reorder is within the group, and the tab list follows', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final left = controller.openTab(TerminalProfile.powerShell);
      final target = controller.splitWorkspace(SplitAxis.horizontal)!;
      final rightA = controller.openTab(TerminalProfile.powerShell);
      final rightB = controller.openTab(TerminalProfile.powerShell);

      expect(controller.reorderTab(rightB, 0), isTrue);

      expect(controller.tabsInGroup(target).map((tab) => tab.id), [
        rightB,
        rightA,
      ]);
      expect(
        stateOf(container).tabs.map((tab) => tab.id),
        [left, rightB, rightA],
        reason: 'the tab list reads left to right across the whole workspace',
      );
    });
  });

  group('the published tree', () {
    test('is the same object when nothing about it moved', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final before = stateOf(container).workspace;

      controller.notifyTitleChanged();

      expect(identical(stateOf(container).workspace, before), isTrue);
    });
  });

  group('a split survives a restart', () {
    test('the groups come back holding the tabs they held', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = ProviderContainer(
        overrides: fakeTerminalOverrides(database: db),
      );
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      final left = controller.openTab(TerminalProfile.powerShell);
      final right = controller.splitWorkspace(SplitAxis.horizontal)!;
      final moved = controller.openTab(TerminalProfile.commandPrompt);
      expect(controller.tabsInGroup(right).map((tab) => tab.id), [moved]);
      controller.persistLayout();
      first.dispose();

      final next = ProviderContainer(
        overrides: fakeTerminalOverrides(database: db, restoreLivePanes: false),
      );
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      final groups = restored.workspace!.groups;

      expect(groups, hasLength(2), reason: 'the split itself came back');
      expect(
        groups.map((group) => group.panes),
        [
          [left],
          [moved],
        ],
      );
    });

    test('a group whose tabs all went is not restored as empty room', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = ProviderContainer(
        overrides: fakeTerminalOverrides(database: db),
      );
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      final left = controller.openTab(TerminalProfile.powerShell);
      final right = controller.splitWorkspace(SplitAxis.horizontal)!;
      final doomed = controller.openTab(TerminalProfile.commandPrompt);
      controller.persistLayout();
      // The tab is taken out from under the stored tree, the way a profile
      // that no longer resolves takes one out at restore.
      controller.closeGroup(right);
      controller.persistLayout();
      first.dispose();

      final next = ProviderContainer(
        overrides: fakeTerminalOverrides(database: db, restoreLivePanes: false),
      );
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);

      expect(restored.workspace!.groups, hasLength(1));
      expect(restored.workspace!.groups.single.panes, [left]);
      expect(restored.tabs.map((tab) => tab.id), [left]);
      expect(doomed, isNot(left));
    });
  });

  group('one chord, two levels of focus', () {
    test('at the edge of a tab the arrow steps to the group next door', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      final left = controller.openTab(TerminalProfile.powerShell);
      controller.splitWorkspace(SplitAxis.horizontal);
      final right = controller.openTab(TerminalProfile.powerShell);

      controller.movePaneFocus(PaneDirection.left);

      expect(stateOf(container).activeTabId, left);

      controller.movePaneFocus(PaneDirection.right);
      expect(stateOf(container).activeTabId, right);
    });

    test('inside a split tab the arrow stays among its panes', () {
      final container = makeContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final slot = controller.splitPane(SplitAxis.horizontal)!;
      controller.openInSlot(slot, TerminalProfile.commandPrompt);
      final tabId = stateOf(container).activeTabId;

      controller.movePaneFocus(PaneDirection.left);

      // The same tab, its other pane — the group tree was never consulted.
      expect(stateOf(container).activeTabId, tabId);
      expect(stateOf(container).activeTab!.focusedPaneId, isNot(slot));
    });
  });
}
