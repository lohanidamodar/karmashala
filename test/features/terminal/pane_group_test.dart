import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// A region of a split holds *tabs*, not one pane.
///
/// The report: *"tab moved to a split pane, doesn't have the tab header to move
/// it away from etc, each split pane should show it's own tab header right?"*.
/// A pane dragged into a split had no header of its own, so there was no way to
/// read what it was, close it, or take it back out — the drag was one-way.
///
/// So a leaf of the pane tree is a [PaneGroup]: the panes stacked in one region
/// and which of them is on top. Everything that used to address "the pane in
/// this region" still addresses it by pane id; what is new is that a region can
/// hold more than one, and that a pane can leave one region for another.
void main() {
  group('PaneGroup', () {
    test('a leaf of the tree is a region holding one pane', () {
      final layout = PaneLayout.single('a');
      final group = layout.root as PaneGroup;
      expect(group.panes, ['a']);
      expect(group.activePaneId, 'a');
      expect(layout.panes, ['a']);
      expect(layout.visiblePanes, ['a']);
    });

    test('a pane added to a region joins it and takes the front', () {
      final layout = PaneLayout.single('a').addPane('a', 'b');

      expect(layout.root, isA<PaneGroup>());
      expect(layout.panes, ['a', 'b']);
      expect((layout.root as PaneGroup).activePaneId, 'b');
      expect(
        layout.visiblePanes,
        ['b'],
        reason: 'only the front pane of a region is on screen',
      );
    });

    test('adding to an unknown pane leaves the layout alone', () {
      expect(PaneLayout.single('a').addPane('zzz', 'b').panes, ['a']);
    });

    test('activate brings another pane in the region to the front', () {
      final layout = PaneLayout.single('a').addPane('a', 'b').activate('a');

      expect((layout.root as PaneGroup).activePaneId, 'a');
      expect(layout.panes, ['a', 'b'], reason: 'the order does not shuffle');
    });

    test('splitting divides the region the pane is in', () {
      final layout = PaneLayout.single(
        'a',
      ).addPane('a', 'b').split('a', SplitAxis.horizontal, 'c', 's1');

      final root = layout.root as PaneSplit;
      expect(root.children, hasLength(2));
      expect((root.children[0] as PaneGroup).panes, ['a', 'b']);
      expect((root.children[1] as PaneGroup).panes, ['c']);
      expect(layout.panes, ['a', 'b', 'c']);
      expect(layout.visiblePanes, ['b', 'c']);
    });

    test('closing one pane of a region leaves the region standing', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .addPane('b', 'c')
          .close('c')!;

      expect(layout.panes, ['a', 'b']);
      expect(layout.root, isA<PaneSplit>(), reason: 'the split is still there');
    });

    test('closing the last pane in a region collapses that region', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .close('b')!;

      expect(layout.root, isA<PaneGroup>());
      expect(layout.panes, ['a']);
    });

    test('closing the front pane hands the region to what is left', () {
      final layout = PaneLayout.single('a').addPane('a', 'b').close('b')!;
      expect((layout.root as PaneGroup).activePaneId, 'a');
    });

    test('a region shares one rectangle with everything stacked in it', () {
      final layout = PaneLayout.single(
        'a',
      ).addPane('a', 'b').split('a', SplitAxis.horizontal, 'c', 's1');
      final rects = layout.rects();

      expect(rects.keys, unorderedEquals(['a', 'b', 'c']));
      expect(rects['a']!.right, rects['b']!.right);
      expect(rects['c']!.left, greaterThan(rects['a']!.left));
    });

    test('directional focus lands on the front pane of the next region', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .addPane('b', 'c');

      expect(
        layout.paneInDirection('a', PaneDirection.right),
        'c',
        reason: 'the pane on screen over there, not one hidden behind it',
      );
      expect(layout.paneInDirection('c', PaneDirection.left), 'a');
    });

    test('a region survives a JSON round trip with its stack and its front', () {
      final layout = PaneLayout.single('a')
          .addPane('a', 'b')
          .activate('a')
          .split('a', SplitAxis.vertical, 'c', 's1');

      final restored = PaneLayout.fromJson(layout.toJson())!;

      expect(restored.panes, layout.panes);
      expect(restored.visiblePanes, layout.visiblePanes);
      final group = restored.groups.first;
      expect(group.panes, ['a', 'b']);
      expect(group.activePaneId, 'a');
    });

    test('a layout stored before regions existed reads as one pane each', () {
      final restored = PaneLayout.fromJson({
        't': 'split',
        'id': 's1',
        'axis': 'h',
        'w': [0.5, 0.5],
        'c': [
          {'t': 'leaf', 'id': 'a'},
          {'t': 'leaf', 'id': 'b'},
        ],
      })!;

      expect(restored.panes, ['a', 'b']);
      expect(restored.groups.map((g) => g.activePaneId), ['a', 'b']);
    });

    test('pruning a missing front pane leaves the region on its survivor', () {
      final layout = PaneLayout.single('a').addPane('a', 'b');
      final pruned = layout.withoutMissing({'a'})!;

      expect(pruned.panes, ['a']);
      expect((pruned.root as PaneGroup).activePaneId, 'a');
    });

    test('pruning every pane of a region drops the region', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1').addPane('b', 'c');

      final pruned = layout.withoutMissing({'a'})!;
      expect(pruned.root, isA<PaneGroup>());
      expect(pruned.panes, ['a']);
    });
  });

  group('a tab moved into a region that already holds something', () {
    late ProviderContainer container;
    late TerminalSessionsController controller;

    setUp(() {
      container = fakeTerminalContainer();
      addTearDown(container.dispose);
      controller = container.read(terminalSessionsControllerProvider.notifier);
    });

    TerminalTab activeTab() =>
        container.read(terminalSessionsControllerProvider).activeTab!;

    test('joins that region rather than needing an empty one', () {
      final host = controller.openTab(TerminalProfile.powerShell);
      final kept = activeTab().layout.panes.single;
      final guest = controller.openTab(TerminalProfile.commandPrompt);
      final guestPane = activeTab().layout.panes.single;
      final instance = controller.instanceFor(guestPane)!;
      controller.activateTab(host);

      expect(controller.canMoveTabIntoSlot(guest, kept), isTrue);
      expect(controller.moveTabIntoSlot(guest, kept), isTrue);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1), reason: 'the tab left the strip');
      final group = state.activeTab!.layout.groups.single;
      expect(group.panes, [kept, guestPane]);
      expect(group.activePaneId, guestPane);
      expect(
        controller.instanceFor(guestPane),
        same(instance),
        reason: 'moving is not launching',
      );
      expect(instance.liveness.value, PaneLiveness.live);
    });

    test('an empty region of the moved tab is not carried in as a tab', () {
      // A region is room, not a session. Stacking one would put a chip in the
      // header for a pane that has nothing behind it — and, if the moved tab's
      // focus was sitting in that region, would hand the keyboard to it.
      final host = controller.openTab(TerminalProfile.powerShell);
      final kept = activeTab().layout.panes.single;
      final guest = controller.openTab(TerminalProfile.commandPrompt);
      final guestPane = activeTab().layout.panes.single;
      final slot = controller.splitPane(SplitAxis.horizontal)!;
      expect(activeTab().focusedPaneId, slot, reason: 'focus is in the room');
      controller.activateTab(host);

      expect(controller.moveTabIntoSlot(guest, kept), isTrue);

      final tab = activeTab();
      expect(tab.layout.groups.single.panes, [kept, guestPane]);
      expect(tab.layout.contains(slot), isFalse);
      expect(tab.focusedPaneId, guestPane);
    });

    test('a region of the tab being moved is not a place to move it', () {
      controller.openTab(TerminalProfile.powerShell);
      final own = activeTab().layout.panes.single;
      expect(controller.canMoveTabIntoSlot(activeTab().id, own), isFalse);
    });
  });

  group('a pane moved between regions', () {
    late ProviderContainer container;
    late TerminalSessionsController controller;

    setUp(() {
      container = fakeTerminalContainer();
      addTearDown(container.dispose);
      controller = container.read(terminalSessionsControllerProvider.notifier);
    });

    TerminalTab activeTab() =>
        container.read(terminalSessionsControllerProvider).activeTab!;

    /// A tab split in two, both halves running: (left, right).
    (String, String) twoRegions() {
      controller.openTab(TerminalProfile.powerShell);
      final left = activeTab().layout.panes.single;
      final right = controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;
      return (left, right);
    }

    test('leaves its old region and joins the new one', () {
      final (left, right) = twoRegions();
      final third = controller.openInSlot(
        controller.splitPane(SplitAxis.vertical)!,
        TerminalProfile.powerShell,
      )!;
      final instance = controller.instanceFor(third)!;

      expect(controller.movePaneIntoRegion(third, left), isTrue);

      final layout = activeTab().layout;
      expect(layout.groups, hasLength(2));
      expect(layout.groupOf(left)!.panes, [left, third]);
      expect(layout.groupOf(right)!.panes, [right]);
      expect(controller.instanceFor(third), same(instance));
      expect(activeTab().focusedPaneId, third);
    });

    test('collapses the region it emptied', () {
      final (left, right) = twoRegions();

      expect(controller.movePaneIntoRegion(right, left), isTrue);

      final layout = activeTab().layout;
      expect(layout.root, isA<PaneGroup>(), reason: 'the split collapsed');
      expect(layout.panes, [left, right]);
    });

    test('fills an empty region, retiring the region\'s own id', () {
      controller.openTab(TerminalProfile.powerShell);
      final second = controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.commandPrompt,
      )!;
      final slot = controller.splitPane(SplitAxis.vertical)!;

      expect(controller.movePaneIntoRegion(second, slot), isTrue);

      final layout = activeTab().layout;
      expect(layout.panes, isNot(contains(slot)));
      expect(layout.groupOf(second)!.panes, [second]);
      expect(layout.groups, hasLength(2), reason: 'first, and the filled slot');
    });

    test('refuses to move a pane into the region it is already in', () {
      final (left, _) = twoRegions();
      final stacked = controller.openTab(TerminalProfile.powerShell);
      final stackedPane = activeTab().layout.panes.single;
      controller.moveTabIntoSlot(stacked, left);

      expect(controller.canMovePaneIntoRegion(stackedPane, left), isFalse);
      expect(controller.movePaneIntoRegion(stackedPane, left), isFalse);
    });

    test('a pane alone in its tab has no region to leave', () {
      controller.openTab(TerminalProfile.powerShell);
      final only = activeTab().layout.panes.single;
      expect(controller.canMovePaneIntoRegion(only, only), isFalse);
    });
  });

  group('closing the last tab in a region', () {
    late ProviderContainer container;
    late TerminalSessionsController controller;

    setUp(() {
      container = fakeTerminalContainer();
      addTearDown(container.dispose);
      controller = container.read(terminalSessionsControllerProvider.notifier);
    });

    TerminalTab activeTab() =>
        container.read(terminalSessionsControllerProvider).activeTab!;

    test('collapses the region, and only then the split', () {
      controller.openTab(TerminalProfile.powerShell);
      final left = activeTab().layout.panes.single;
      final right = controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;
      final guest = controller.openTab(TerminalProfile.powerShell);
      final guestPane = activeTab().layout.panes.single;
      controller.moveTabIntoSlot(guest, right);

      // One of two in the region: the region stays, the split stays.
      controller.closePane(guestPane, detach: false);
      expect(activeTab().layout.groups, hasLength(2));
      expect(activeTab().layout.groupOf(right)!.panes, [right]);

      // The last one in the region: the region goes, and the split with it.
      controller.closePane(right, detach: false);
      expect(activeTab().layout.root, isA<PaneGroup>());
      expect(activeTab().layout.panes, [left]);
    });

    test('the pane behind it comes forward, and takes the keyboard', () {
      controller.openTab(TerminalProfile.powerShell);
      final first = activeTab().layout.panes.single;
      final guest = controller.openTab(TerminalProfile.commandPrompt);
      final guestPane = activeTab().layout.panes.single;
      controller.activateTab(activeTab().id);
      controller.moveTabIntoSlot(guest, first);
      expect(activeTab().focusedPaneId, guestPane);

      controller.closePane(guestPane, detach: false);

      expect(activeTab().layout.groups.single.activePaneId, first);
      expect(activeTab().focusedPaneId, first);
    });

    test('a pane that exits cleanly beside a stack-mate takes itself off', () async {
      controller.openTab(TerminalProfile.powerShell);
      final first = activeTab().layout.panes.single;
      final guest = controller.openTab(TerminalProfile.commandPrompt);
      final guestPane = activeTab().layout.panes.single;
      controller.moveTabIntoSlot(guest, first);

      (controller.instanceFor(guestPane)! as FakeTerminalInstance)
          .exitCleanly();
      await Future<void>.delayed(Duration.zero);

      expect(
        activeTab().layout.panes,
        [first],
        reason: 'there is somewhere else to look, so the finished shell goes',
      );
    });
  });

  group('regions survive a save and a restore', () {
    test('the stack and its front pane come back', () {
      final database = AppDatabase.memory();
      addTearDown(database.close);

      String hostPane;
      String guestPane;
      String tabId;
      {
        final container = fakeTerminalContainer(database: database);
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        tabId = controller.openTab(TerminalProfile.powerShell);
        hostPane = container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .layout
            .panes
            .single;
        final guest = controller.openTab(TerminalProfile.commandPrompt);
        guestPane = container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .layout
            .panes
            .single;
        controller.activateTab(tabId);
        controller.splitPane(SplitAxis.horizontal);
        controller.moveTabIntoSlot(guest, hostPane);
        controller.persistWorkspace();
        container.dispose();
      }

      final container = fakeTerminalContainer(database: database);
      addTearDown(container.dispose);
      final restored = container.read(terminalSessionsControllerProvider);

      expect(restored.tabs, hasLength(1));
      final layout = restored.tabs.single.layout;
      expect(
        layout.groups,
        hasLength(1),
        reason: 'the empty region is room a reboot has already taken away',
      );
      expect(layout.groups.single.panes, [hostPane, guestPane]);
      expect(layout.groups.single.activePaneId, guestPane);
    });

    test('a restore drops a pane that no longer exists, not the region', () {
      final database = AppDatabase.memory();
      addTearDown(database.close);

      String hostPane;
      String guestPane;
      {
        final container = fakeTerminalContainer(database: database);
        final controller = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        final tabId = controller.openTab(TerminalProfile.powerShell);
        hostPane = container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .layout
            .panes
            .single;
        final guest = controller.openTab(TerminalProfile.commandPrompt);
        guestPane = container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .layout
            .panes
            .single;
        controller.activateTab(tabId);
        controller.moveTabIntoSlot(guest, hostPane);
        controller.persistWorkspace();
        container.dispose();
      }

      // The front pane's row goes, the way a removed WSL distro takes one.
      database.execute('DELETE FROM terminal_panes WHERE id = ?', [guestPane]);

      final container = fakeTerminalContainer(database: database);
      addTearDown(container.dispose);
      final restored = container.read(terminalSessionsControllerProvider);

      final layout = restored.tabs.single.layout;
      expect(layout.panes, [hostPane]);
      expect(layout.groups.single.activePaneId, hostPane);
      expect(restored.tabs.single.focusedPaneId, hostPane);
    });
  });
}
