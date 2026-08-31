import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/detach_policy.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// What happens to a split pane when the thing in it finishes.
///
/// The report: "how to close the split — even after terminal was exit with exit
/// command the split pane was still there". Typing `exit` is a request to be
/// done with that shell, and a split is a working surface rather than a record,
/// so the pane goes and the split collapses. The two exceptions are the ones
/// the app already argues for elsewhere: an agent session's scrollback is the
/// point of the session, and the last pane in a tab is where the output of the
/// thing that just finished still is.
void main() {
  group('shouldCollapseOnExit', () {
    test('a plain pane that exited cleanly in a split goes', () {
      expect(
        shouldCollapseOnExit(
          isSplit: true,
          isAgentSession: false,
          exitCode: 0,
        ),
        isTrue,
      );
    });

    test('a failure stays, holding the error somebody split to watch', () {
      expect(
        shouldCollapseOnExit(
          isSplit: true,
          isAgentSession: false,
          exitCode: 1,
        ),
        isFalse,
      );
      expect(
        shouldCollapseOnExit(
          isSplit: true,
          isAgentSession: false,
          exitCode: null,
        ),
        isFalse,
        reason: 'an exit status we never learned is not a clean one',
      );
    });

    test('an agent session stays, split or not', () {
      expect(
        shouldCollapseOnExit(isSplit: true, isAgentSession: true, exitCode: 0),
        isFalse,
      );
      expect(
        shouldCollapseOnExit(isSplit: false, isAgentSession: true, exitCode: 0),
        isFalse,
      );
    });

    test('the only pane in a tab stays, so its output can be read', () {
      expect(
        shouldCollapseOnExit(
          isSplit: false,
          isAgentSession: false,
          exitCode: 0,
        ),
        isFalse,
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
      final second = controller.splitPane(
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
      final second = controller.splitPane(
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

    test('two exiting together leave the tab standing, not empty', () async {
      // The decision to collapse is taken in the liveness callback and applied
      // a microtask later. Both panes of a split dying in the same task queued
      // two collapses while the tab still had two panes, and the second found
      // itself alone and took the whole tab with it — breaking the one rule
      // the feature is built on.
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
      final second = controller.splitPane(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      )!;

      (controller.instanceFor(first)! as FakeTerminalInstance).exitCleanly();
      (controller.instanceFor(second)! as FakeTerminalInstance).exitCleanly();
      await Future<void>.delayed(Duration.zero);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1), reason: 'the tab is not a casualty');
      expect(state.activeTab!.layout.panes, hasLength(1));
    });

    test('stays when it is the only pane in its tab', () async {
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
      expect(state.tabs, hasLength(1));
      expect(state.activeTab!.layout.panes, [only]);
      expect(state.livenessOf(only), PaneLiveness.exited);
    });
  });
}
