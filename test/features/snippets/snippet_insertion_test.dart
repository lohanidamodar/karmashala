import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/snippets/application/snippet_insertion.dart';
import 'package:karmashala/src/features/snippets/domain/command_snippet.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// What actually reaches a pane when a snippet is picked.
///
/// Every case here reads the bytes the pane would have handed its PTY, because
/// the whole design decision — **type, do not send** — is invisible at any
/// other level: a tool that typed and submitted would return the same
/// "delivered" as one that only typed. `written` is `Terminal.onOutput`, the
/// same seam `terminal_control_tools_test.dart` measures `terminal_run` at, so
/// the two tools can be compared directly: `terminal_run` writes
/// `['flutter test', '\r']` and this writes `['flutter test']`.
///
/// **No real pane is ever involved.** The instances are fakes with no PTY
/// behind them, so nothing here can reach a shell the owner is using.
void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: [...fakeTerminalOverrides()]);
  });
  tearDown(() => container.dispose());

  TerminalSessionsController controller() =>
      container.read(terminalSessionsControllerProvider.notifier);
  TerminalSessionsState state() =>
      container.read(terminalSessionsControllerProvider);

  CommandSnippet snippet({
    String id = 'sn1',
    String command = 'flutter test',
    String? shellId,
    bool submit = false,
  }) => CommandSnippet(
    id: id,
    label: 'A snippet',
    command: command,
    shellId: shellId,
    submit: submit,
    createdAt: testTime,
    updatedAt: testTime,
  );

  /// Opens a pane and starts recording what it would send to its process.
  ({String paneId, List<String> written}) pane([
    TerminalProfile profile = TerminalProfile.powerShell,
  ]) {
    controller().openTab(profile);
    final paneId = state().activeTab!.focusedPaneId;
    final written = <String>[];
    controller().instanceFor(paneId)!.terminal.onOutput = written.add;
    return (paneId: paneId, written: written);
  }

  SnippetInsertionResult insert(
    String paneId,
    CommandSnippet value,
  ) => insertSnippet(
    terminals: controller(),
    state: state(),
    snippet: value,
    paneId: paneId,
  );

  group('type, do not send', () {
    test('a picked snippet lands at the prompt with no carriage return', () {
      final target = pane();

      final result = insert(target.paneId, snippet());

      expect(result.outcome, SnippetOutcome.typed);
      expect(
        target.written,
        ['flutter test'],
        reason:
            'the whole safety story: a saved command is text the user reads '
            'and presses Enter on, never something a fuzzy-matched list runs '
            'for them',
      );
      expect(
        result.message,
        isNull,
        reason: 'a command in the pane you are looking at is its own feedback',
      );
    });

    test('a snippet the user marked "runs" submits, and says it did', () {
      final target = pane();

      final result = insert(target.paneId, snippet(submit: true));

      expect(result.outcome, SnippetOutcome.submitted);
      // Split exactly the way `terminal_run` splits it, and a CR rather than a
      // newline for the same reason: a PTY line discipline reads CR as submit.
      expect(target.written, ['flutter test', '\r']);
    });

    test('a stored newline cannot smuggle a submit past submit=false', () {
      final target = pane();

      insert(target.paneId, snippet(command: 'git add -A\nrm -rf build'));

      expect(target.written, ['git add -A rm -rf build']);
      expect(target.written.join(), isNot(contains('\n')));
      expect(target.written.join(), isNot(contains('\r')));
    });
  });

  group('an agent pane is somebody\'s live session', () {
    test('a submitting snippet is typed there and NOT submitted', () {
      final opened = controller().openAgentTab(
        const AgentPaneLaunch(agentId: 'claude', executable: 'claude'),
      );
      final written = <String>[];
      controller().instanceFor(opened.paneId)!.terminal.onOutput = written.add;

      final result = insert(opened.paneId, snippet(submit: true));

      expect(result.outcome, SnippetOutcome.typedIntoAgentPane);
      expect(
        written,
        ['flutter test'],
        reason:
            'a carriage return here takes a turn as if the user had pressed '
            'it — the reason terminal_run refuses an agent pane outright',
      );
      expect(result.message, contains('without sending'));
    });

    test('and an ordinary snippet is typed there in silence', () {
      final opened = controller().openAgentTab(
        const AgentPaneLaunch(agentId: 'codex', executable: 'codex'),
      );
      final written = <String>[];
      controller().instanceFor(opened.paneId)!.terminal.onOutput = written.add;

      final result = insert(opened.paneId, snippet());

      expect(result.outcome, SnippetOutcome.typedIntoAgentPane);
      expect(written, ['flutter test']);
      expect(
        result.message,
        isNull,
        reason: 'nothing surprising happened, so there is nothing to say',
      );
    });
  });

  group('a pane that cannot take it', () {
    test('a pane that closed under the open picker is reported, not typed', () {
      final target = pane();
      controller().closeTab(state().activeTab!.id, detach: false);

      final result = insert(target.paneId, snippet());

      expect(result.outcome, SnippetOutcome.noPane);
      expect(result.delivered, isFalse);
      expect(target.written, isEmpty);
    });

    test('a pane whose process exited is reported, not typed', () {
      final target = pane();
      (controller().instanceFor(target.paneId)! as FakeTerminalInstance)
          .exitWith(1);

      final result = insert(target.paneId, snippet());

      expect(result.outcome, SnippetOutcome.paneNotLive);
      expect(target.written, isEmpty);
      expect(result.message, contains('exited'));
    });
  });

  group('the active terminal', () {
    test('is the focused pane of the active tab, not the focused widget', () {
      // The property the palette depends on: "active" is controller state, so
      // a modal taking the keyboard cannot change the answer. Nothing here
      // touches focus at all, and the target is still right.
      pane();
      final second = pane(TerminalProfile.commandPrompt);

      final target = resolveSnippetTarget(controller(), state())!;

      expect(target.paneId, second.paneId);
      expect(target.shell, TerminalShell.commandPrompt);
      expect(target.isAgentPane, isFalse);
      expect(target.live, isTrue);
    });

    test('carries the pane\'s own shell, not the host\'s', () {
      controller().openTab(
        const TerminalProfile(
          id: 'wsl:Ubuntu',
          label: 'Ubuntu (WSL)',
          shell: TerminalShell.wsl,
          wslDistribution: 'Ubuntu',
        ),
      );

      final target = resolveSnippetTarget(controller(), state())!;

      expect(target.shellId, 'wsl');
      expect(
        target.filter([
          snippet(id: 'any'),
          snippet(id: 'wsl', shellId: 'wsl'),
          snippet(id: 'pwsh', shellId: 'powerShell'),
        ]).map((s) => s.id),
        ['any', 'wsl'],
        reason:
            'a PowerShell snippet is absent from a WSL pane on the very same '
            'Windows machine',
      );
    });

    test('is null when there is no tab at all', () {
      expect(resolveSnippetTarget(controller(), state()), isNull);
    });

    test('is null for an empty region nobody has filled', () {
      pane();
      controller().splitPane(SplitAxis.horizontal);

      expect(
        resolveSnippetTarget(controller(), state()),
        isNull,
        reason: 'a split with nothing in it is not a terminal to type into',
      );
    });
  });
}
