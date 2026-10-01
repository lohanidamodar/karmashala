import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Closing a pane detaches it — but not *every* pane.
///
/// Detaching rather than killing is right for the thing this app is for: an
/// agent mid-turn, a build, a dev server, an ssh session. It was applied to
/// every live pane, so opening a shell, typing nothing and closing the tab left
/// a PowerShell running with no tab, a row in the layout and (since the
/// tiering work) a spool. Multiplied by a working day, that is a background
/// session list nobody asked for and a slower restore every morning.
///
/// The background list itself is gone (2026-09-30): the server runs every
/// terminal whether a pane shows it or not, so the controller drops the pane
/// on close. The rule stays a pure function; the controller cases pin the drop.
void main() {
  group('the rule', () {
    test('a dead pane is released — there is nothing to keep', () {
      expect(
        shouldDetachOnClose(
          isLive: false,
          isAgentSession: false,
          commandRunning: true,
          nonBlankLines: 1000,
          greetingLines: null,
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
          greetingLines: null,
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
          greetingLines: null,
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
          greetingLines: null,
        ),
        isFalse,
      );
    });

    test('an un-instrumented shell is kept only if it has history', () {
      bool detach(int lines, {int? greeting}) => shouldDetachOnClose(
        isLive: true,
        isAgentSession: false,
        commandRunning: null,
        nonBlankLines: lines,
        greetingLines: greeting,
      );

      expect(detach(0), isFalse, reason: 'opened it, typed nothing');
      expect(detach(kIdleShellHistoryLines), isFalse, reason: 'a banner');
      expect(detach(kIdleShellHistoryLines + 1), isTrue, reason: 'used');
    });

    test('the history it counts is the shell\'s own, not its prompt', () {
      // The owner's report — "empty wsl terminal stays in the background
      // instead of just ending" — measured through a real ConPTY against
      // archlinux/zsh/starship, whose prompt is three rows per command:
      //
      //   idle, untouched          2      <- the greeting
      //   after 1 silent command   5
      //   after 2 silent commands  8      <- used to be kept
      //   after `pwd`             12
      //   after `ls`             106
      //
      // Two commands that printed nothing parked a shell in the background
      // list, where a restart puts it straight back. Counting from the
      // greeting instead of from zero is what tells the redraws apart from
      // output.
      bool detach(int lines) => shouldDetachOnClose(
        isLive: true,
        isAgentSession: false,
        commandRunning: null,
        nonBlankLines: lines,
        greetingLines: 2,
      );

      expect(detach(2), isFalse, reason: 'the greeting alone');
      expect(detach(5), isFalse, reason: 'one command that printed nothing');
      expect(detach(8), isFalse, reason: 'two of them — the reported bug');
      expect(detach(12), isTrue, reason: 'output past the prompts');
      expect(detach(106), isTrue, reason: 'an `ls`');
    });

    test('a long MOTD is a greeting, not history', () {
      // The case the old fixed six conceded it got wrong: a login banner
      // longer than the threshold used to keep every such shell for ever.
      bool detach(int lines) => shouldDetachOnClose(
        isLive: true,
        isAgentSession: false,
        commandRunning: null,
        nonBlankLines: lines,
        greetingLines: 40,
      );

      expect(detach(40), isFalse, reason: 'the banner is not history');
      expect(detach(40 + kIdleShellHistoryLines), isFalse);
      expect(detach(40 + kIdleShellHistoryLines + 1), isTrue, reason: 'used');
    });

    test('no greeting counts from zero, as it did before greetings', () {
      // A pane the user never ran anything in has none to record, and the
      // smaller reading only ever keeps more — the safe direction.
      expect(
        shouldDetachOnClose(
          isLive: true,
          isAgentSession: false,
          commandRunning: null,
          nonBlankLines: kIdleShellHistoryLines + 1,
          greetingLines: null,
        ),
        isTrue,
      );
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

    // Since 2026-09-30 the rule above no longer decides a close: the server
    // keeps every terminal whether a pane shows it or not, so closing a tab
    // drops the pane — a disconnect — and parks nothing in this window. What
    // a used shell or an agent is owed (not being killed) is the server's
    // (`end_hosted_session_test.dart`).
    test('closing a used shell drops its pane and parks nothing', () {
      final pane = openPane();
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;
      giveShellHistory(instance);

      controller.closeTab(
        container.read(terminalSessionsControllerProvider).activeTabId!,
      );

      expect(container.read(terminalSessionsControllerProvider).detached, []);
      expect(controller.instanceFor(pane), isNull);
      expect(instance.disposed, isTrue);
    });

    test('closing an agent pane drops it too, whatever it printed', () {
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          title: 'a session',
        ),
      );

      controller.closeTab(opened.tabId);

      expect(container.read(terminalSessionsControllerProvider).detached, []);
      expect(controller.instanceFor(opened.paneId), isNull);
    });

    test('a shell with a multi-line prompt is not parked by its redraws', () {
      // End to end, in the shape the ConPTY measurement found: a two-row
      // greeting, then two commands that printed nothing, each leaving another
      // prompt behind. Eight non-blank lines and not one of them is output.
      final pane = openPane();
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;
      instance.greetingLines = 2;
      instance.terminal.write('~\r\n> true\r\n' * 4);

      controller.closeTab(
        container.read(terminalSessionsControllerProvider).activeTabId!,
      );

      expect(
        container.read(terminalSessionsControllerProvider).detached,
        isEmpty,
        reason: 'the owner closed an empty terminal; it should just end',
      );
      expect(controller.instanceFor(pane), isNull);
    });

    test('and is dropped the same once it has printed something', () {
      final pane = openPane();
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;
      instance.greetingLines = 2;
      instance.terminal.write('~\r\n> true\r\n' * 4);
      instance.terminal.write('a long build\r\n' * 8);

      controller.closeTab(
        container.read(terminalSessionsControllerProvider).activeTabId!,
      );

      expect(container.read(terminalSessionsControllerProvider).detached, []);
      expect(controller.instanceFor(pane), isNull);
    });

    test('a released pane leaves no layout row behind', () {
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
