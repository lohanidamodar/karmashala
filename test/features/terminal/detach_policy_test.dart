import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/detach_policy.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Closing a pane detaches it — but not *every* pane.
///
/// Detaching rather than killing is right for the thing this app is for: an
/// agent mid-turn, a build, a dev server, an ssh session. It was applied to
/// every live pane, so opening a shell, typing nothing and closing the tab left
/// a PowerShell running with no tab, a row in the workspace and (since the
/// tiering work) a spool. Multiplied by a working day, that is a background
/// session list nobody asked for and a slower restore every morning.
void main() {
  group('the rule', () {
    test('a dead pane is released — there is nothing to keep', () {
      expect(
        shouldDetachOnClose(
          isLive: false,
          isAgentSession: false,
          commandRunning: true,
          nonBlankLines: 1000,
        ),
        isFalse,
      );
    });

    test('an agent session is always kept', () {
      // It is the unit of work the app is about, it may be mid-turn, and its
      // transcript is the point.
      expect(
        shouldDetachOnClose(
          isLive: true,
          isAgentSession: true,
          commandRunning: false,
          nonBlankLines: 0,
        ),
        isTrue,
      );
    });

    test('an executing command is always kept', () {
      expect(
        shouldDetachOnClose(
          isLive: true,
          isAgentSession: false,
          commandRunning: true,
          nonBlankLines: 0,
        ),
        isTrue,
      );
    });

    test('an instrumented shell at an idle prompt is released', () {
      // OSC 133 said so directly; there is no guessing to do, and the buffer
      // does not get a vote.
      expect(
        shouldDetachOnClose(
          isLive: true,
          isAgentSession: false,
          commandRunning: false,
          nonBlankLines: 5000,
        ),
        isFalse,
      );
    });

    test('an un-instrumented shell is kept only if it has history', () {
      bool detach(int lines) => shouldDetachOnClose(
        isLive: true,
        isAgentSession: false,
        commandRunning: null,
        nonBlankLines: lines,
      );

      expect(detach(0), isFalse, reason: 'opened it, typed nothing');
      expect(detach(kIdleShellHistoryLines), isFalse, reason: 'a banner');
      expect(detach(kIdleShellHistoryLines + 1), isTrue, reason: 'used');
    });
  });

  group('through the controller', () {
    late ProviderContainer container;
    late TerminalSessionsController controller;

    setUp(() {
      container = fakeTerminalContainer();
      controller = container.read(terminalSessionsControllerProvider.notifier);
    });
    tearDown(() => container.dispose());

    String openPane() {
      controller.openTab(TerminalProfile.powerShell);
      return container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
    }

    test('closing an idle shell ends it rather than parking it', () {
      final tabId = container
          .read(terminalSessionsControllerProvider)
          .activeTabId;
      final pane = openPane();
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;

      controller.closeTab(
        container.read(terminalSessionsControllerProvider).activeTabId!,
      );

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.detached, isEmpty, reason: 'no background session appears');
      expect(controller.instanceFor(pane), isNull, reason: 'the pane is freed');
      expect(instance.disposed, isTrue, reason: 'the process is ended');
      expect(tabId, isNull);
    });

    test('closing a used shell parks it, as it always did', () {
      final pane = openPane();
      giveShellHistory(controller.instanceFor(pane)!);

      controller.closeTab(
        container.read(terminalSessionsControllerProvider).activeTabId!,
      );

      expect(
        container.read(terminalSessionsControllerProvider).detached.single
            .paneId,
        pane,
      );
      expect(controller.instanceFor(pane), isNotNull);
    });

    test('closing an agent pane parks it even with an empty buffer', () {
      // An agent that has printed nothing yet is an agent that has just been
      // started, which is the worst possible moment to kill it.
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          title: 'a session',
        ),
      );

      controller.closeTab(opened.tabId);

      expect(
        container.read(terminalSessionsControllerProvider).detached.single
            .paneId,
        opened.paneId,
      );
    });

    test('a released pane leaves no workspace row behind', () {
      final pane = openPane();
      controller.closeTab(
        container.read(terminalSessionsControllerProvider).activeTabId!,
      );

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, isEmpty);
      expect(state.detached, isEmpty);
      // Nothing is left to persist, which is what removes the stored row and
      // the scrollback that hung off it.
      expect(controller.instanceFor(pane), isNull);
    });
  });
}
