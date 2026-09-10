import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// What happens to a pane when the thing in it finishes.
///
/// Two reports, one rule. "how to close the split — even after terminal was
/// exit with exit command the split pane was still there", and then *"typing
/// exit on terminal tab, should also close the tab right"*. Typing `exit` is a
/// request to be done with that shell, and a pane is a working surface rather
/// than a record of one — at whatever scope it occupies, so the last pane in a
/// tab takes the tab with it.
///
/// The two exceptions carry the whole safety story: an agent session's
/// scrollback is the point of the session, and a non-zero exit is evidence
/// somebody opened the terminal to read.
void main() {
  group('shouldCollapseOnExit', () {
    test('a plain pane that exited cleanly goes', () {
      expect(
        shouldCollapseOnExit(isAgentSession: false, exitCode: 0),
        isTrue,
      );
    });

    test('a failure stays, holding the error somebody opened it to read', () {
      expect(
        shouldCollapseOnExit(isAgentSession: false, exitCode: 1),
        isFalse,
      );
      expect(
        shouldCollapseOnExit(isAgentSession: false, exitCode: null),
        isFalse,
        reason: 'an exit status we never learned is not a clean one',
      );
    });

    test('an agent session stays — ending one may have cost real money', () {
      expect(
        shouldCollapseOnExit(isAgentSession: true, exitCode: 0),
        isFalse,
      );
    });

    test('the only pane in a tab goes too — the owner asked for the tab', () {
      // The rule no longer takes the layout into account at all, which is the
      // point: `exit` means the same thing wherever it is typed.
      expect(
        shouldCollapseOnExit(isAgentSession: false, exitCode: 0),
        isTrue,
      );
    });
  });

  group('a pane whose process exits', () {
    test('collapses the split it was in', () async {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final second = controller.splitPaneWith(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      )!;
      final instance = controller.instanceFor(second)! as FakeTerminalInstance;

      instance.exitCleanly();
      await Future<void>.delayed(Duration.zero);

      final tab = container.read(terminalSessionsControllerProvider).activeTab!;
      expect(tab.layout.panes, hasLength(1));
      expect(tab.layout.panes, isNot(contains(second)));
      expect(
        tab.focusedPaneId,
        tab.layout.panes.single,
        reason: 'the surviving pane takes the keyboard',
      );
    });

    test('is not detached — it already ended', () async {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final second = controller.splitPaneWith(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      )!;
      final instance = controller.instanceFor(second)! as FakeTerminalInstance;

      instance.exitCleanly();
      await Future<void>.delayed(Duration.zero);

      final state = container.read(terminalSessionsControllerProvider);
      expect(
        state.detached,
        isEmpty,
        reason: 'a background list of dead shells is what detaching is not for',
      );
    });

    test('two exiting together take the tab, once, without throwing', () async {
      // The decision to collapse is taken in the liveness callback and applied
      // a microtask later, so both panes of a split dying in the same task
      // queue two collapses. The first close can take the tab and the second
      // pane with it, which is why the decision is re-asked in the microtask:
      // the second must find itself tab-less and do nothing rather than close
      // a pane that has already gone.
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final first = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final second = controller.splitPaneWith(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      )!;

      (controller.instanceFor(first)! as FakeTerminalInstance).exitCleanly();
      (controller.instanceFor(second)! as FakeTerminalInstance).exitCleanly();
      await Future<void>.delayed(Duration.zero);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, isEmpty, reason: 'both shells were dismissed');
    });

    test('takes the tab when the only thing beside it is an empty region',
        () async {
      // An empty region is not another pane, so nothing is left to read the
      // output in and the tab goes — the same answer `closePane` already gives
      // a layout whose remaining regions are all empty.
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final only = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      controller.splitPane(SplitAxis.horizontal);

      (controller.instanceFor(only)! as FakeTerminalInstance).exitCleanly();
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        isEmpty,
      );
    });

    test('takes its tab when it is the only pane in it', () async {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final only = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(only)! as FakeTerminalInstance;

      instance.exitCleanly();
      await Future<void>.delayed(Duration.zero);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, isEmpty, reason: 'the owner asked for the tab to go');
      expect(controller.instanceFor(only), isNull, reason: 'and the pane with it');
    });

    test('a failure keeps its tab, holding the error unread', () async {
      // The evidence case, and the reason this is not behind a setting: what
      // closes is a shell the user told to end, and a crash is not that.
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final only = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;

      (controller.instanceFor(only)! as FakeTerminalInstance).exitWith(1);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1));
      expect(state.activeTab!.layout.panes, [only]);
      expect(state.livenessOf(only), PaneLiveness.exited);
    });
  });
}
