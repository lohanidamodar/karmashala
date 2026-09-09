/// The terminal's verbs, held apart from anything that draws them.
///
/// A library of its own rather than a `part` of `terminal_panel.dart`: nothing
/// here is private and nothing here draws, and five files outside this folder
/// reach [TerminalActions] already. `terminal_panel.dart` re-exports it so none
/// of them had to move.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../application/terminal_scroll.dart';
import '../application/terminal_search_controller.dart';
import '../application/terminal_sessions_controller.dart';
import '../data/terminal_instance.dart';
import '../domain/command_blocks.dart';
import '../domain/pane_layout.dart';
import '../domain/pane_restart.dart';
import '../domain/terminal_profile.dart';
import '../../../app/shell/shell_shortcuts.dart';
import 'command_history_sheet.dart';
import 'session_status.dart';
import '../application/terminal_profiles.dart';

/// Everything the terminal surface can be asked to *do*, in one place.
///
/// The terminal used to be a dock that owned both its tab strip and its panes.
/// Loop 47 moved the tabs into the shell's workbench strip, so the strip and the
/// panes are now built by different widgets — and both need the same verbs.
/// Holding them here keeps that a re-placement rather than a fork: there is
/// still exactly one implementation of "open a tab", "split", "find".
class TerminalActions {
  const TerminalActions(this.ref);

  final WidgetRef ref;

  TerminalSessionsController get _sessions =>
      ref.read(terminalSessionsControllerProvider.notifier);

  List<TerminalProfile> profiles() => ref.read(terminalProfilesProvider);

  TerminalProfile defaultProfile() {
    final id = ref.read(settingsControllerProvider).defaultTerminalProfileId;
    return resolveTerminalProfile(id, profiles());
  }

  /// The working directory a new terminal should start in, derived from the
  /// selected repository when it is compatible with the chosen shell.
  String? workingDirFor(TerminalProfile profile) {
    final repoId = ref.read(selectedRepositoryIdProvider);
    if (repoId == null) return null;
    final repo = ref.read(repositoryDaoProvider).getById(repoId);
    if (repo == null) return null;
    final env = ref
        .read(executionEnvironmentDaoProvider)
        .getById(repo.path.environmentId);
    final repoIsWindows = env?.kind == EnvironmentKind.windowsNative;
    if (profile.shell == TerminalShell.ssh) {
      return env?.sshHostId == profile.sshHostId ? repo.path.path : null;
    }
    if (profile.shell == TerminalShell.wsl) return repo.path.path;
    return repoIsWindows ? repo.path.path : null;
  }

  void open(TerminalProfile profile) {
    _sessions.openTab(profile, workingDirectory: workingDirFor(profile));
  }

  /// Divides the focused **workspace group**, leaving the new one empty for the
  /// user to fill — see [TerminalSessionsController.splitWorkspace].
  ///
  /// The buttons and the chords split the workspace; splitting a *pane* inside
  /// one tab is the pane's own verb, on its own menu.
  void split(SplitAxis axis) => _sessions.splitWorkspace(axis);

  /// Divides the focused pane inside its tab — see
  /// [TerminalSessionsController.splitPane].
  void splitPane(SplitAxis axis) => _sessions.splitPane(axis);

  /// Starts a terminal in the empty region [slotPaneId].
  void openInSlot(String slotPaneId, [TerminalProfile? profile]) {
    final chosen = profile ?? defaultProfile();
    _sessions.openInSlot(
      slotPaneId,
      chosen,
      workingDirectory: workingDirFor(chosen),
    );
  }

  void closeFocusedPane() {
    final tab = ref.read(terminalSessionsControllerProvider).activeTab;
    if (tab != null) _sessions.closePane(tab.focusedPaneId);
  }

  void openSearch() {
    final tab = ref.read(terminalSessionsControllerProvider).activeTab;
    if (tab == null) return;
    // An empty region has no scrollback to search, and a search bar bound to
    // one would answer every query with nothing.
    if (_sessions.instanceFor(tab.focusedPaneId) == null) return;
    ref.read(terminalSearchControllerProvider.notifier).open(tab.focusedPaneId);
  }

  /// The focused pane's live instance, if there is one.
  TerminalInstance? focusedInstance() {
    final tab = ref.read(terminalSessionsControllerProvider).activeTab;
    if (tab == null) return null;
    return _sessions.instanceFor(tab.focusedPaneId);
  }

  /// The commands OSC 133 saw in the focused pane. Empty for any pane without
  /// shell integration, which is what keeps every affordance invisible there.
  List<CommandBlock> focusedBlocks() {
    final recorder = focusedInstance()?.commandBlocks;
    if (recorder == null) return const [];
    recorder.tracker.pruneEvicted();
    return recorder.tracker.blocks;
  }

  /// Scrolls the focused pane to the command before or after the one on screen.
  void jumpCommand({required bool forward}) {
    final instance = focusedInstance();
    final recorder = instance?.commandBlocks;
    if (instance == null || recorder == null) return;
    recorder.tracker.pruneEvicted();

    final scroll = instance.scrollController;
    if (!scroll.hasClients) return;
    final position = scroll.position;
    final lineCount = instance.terminal.buffer.lines.length;
    if (position.maxScrollExtent <= 0 || lineCount == 0) return;
    final lineHeight =
        (position.maxScrollExtent + position.viewportDimension) / lineCount;
    final centreLine =
        ((position.pixels + position.viewportDimension / 2) / lineHeight)
            .floor();

    final target = forward
        ? recorder.tracker.nextAfter(centreLine)
        : recorder.tracker.previousBefore(centreLine);
    scrollPaneTo(instance, target);
  }

  void scrollPaneTo(TerminalInstance instance, CommandBlock? block) {
    final line = block?.promptLine;
    if (line == null) return;
    scrollTerminalToLine(
      instance.scrollController,
      line: line,
      lineCount: instance.terminal.buffer.lines.length,
    );
  }

  /// What the button on a dormant pane's status bar does.
  ///
  /// One button, two verbs, and the routing between them is
  /// [shouldResumeRatherThanRestart] rather than anything decided here: a
  /// restored **agent** pane is a stored conversation and gets a real resume,
  /// everything else re-runs the line it recorded. The bar says which by
  /// reading the same rule, so the word on the button and the code behind it
  /// cannot drift apart.
  ///
  /// The refusal is shown rather than swallowed. A resume that cannot happen —
  /// an agent that never named its conversation, a repository since removed —
  /// leaves the pane exactly as it was, and a button that appears to do nothing
  /// is indistinguishable from a broken one.
  Future<void> startOrResumePane(BuildContext context, String paneId) async {
    final instance = _sessions.instanceFor(paneId);
    if (instance == null) return;
    if (!shouldResumeRatherThanRestart(
      liveness: instance.liveness.value,
      isAgentPane: instance.agentLaunch != null,
    )) {
      _sessions.startPane(paneId);
      return;
    }
    final result = await ref
        .read(explorerActionsProvider)
        .resumeRestoredPane(paneId);
    final message = result.message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Shows what is still running with no tab, and lets the user bring one back
  /// or end it.
  Future<void> showBackgroundSessions(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final detached = ref.watch(terminalDetachedProvider);
          return BackgroundSessionsDialog(
            sessions: detached,
            livenessOf: (paneId) =>
                ref.read(terminalPaneLivenessProvider(paneId)),
            onAttach: (paneId) {
              _sessions.reattachSession(paneId);
              Navigator.of(context).pop();
            },
            onEnd: _sessions.endSession,
            onEndAll: () {
              _sessions.endAllDetached();
              Navigator.of(context).pop();
            },
          );
        },
      ),
    );
  }

  /// Shows what a restart brought back as history, and offers to continue it —
  /// one session, or all of them.
  ///
  /// Reached from the toolbar's badge and from quick open, and from nowhere
  /// per-tab: this is a question about the whole window, and a tab menu could
  /// only ever answer it for one tab.
  Future<void> showRestoredSessions(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // The container, not this [WidgetRef]. Quick open pops itself *before*
    // running the command it was asked for, so by the time a resume finishes
    // the widget this ref belongs to may be gone — and the bulk verb outlives
    // even the dialog, by design. A container is the app's, not a widget's.
    final container = ProviderScope.containerOf(context, listen: false);
    await showDialog<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          // Watched, so a row leaves the list the moment its pane comes up —
          // the same live shape [showBackgroundSessions] has.
          final panes = ref.watch(restoredAgentPanesProvider);
          final state = ref.watch(terminalSessionsControllerProvider);
          final sessions = ref.read(
            terminalSessionsControllerProvider.notifier,
          );
          return RestoredSessionsDialog(
            sessions: [
              for (final paneId in panes)
                RestoredSession(
                  paneId: paneId,
                  title: sessions.titleForPane(paneId),
                  workingDirectory: state.directoryOf(paneId),
                ),
            ],
            // Deliberately leaves the dialog open: with four sessions listed,
            // resuming them one at a time is a thing somebody might actually
            // want, and the row disappears as its pane comes up.
            onResume: (paneId) async {
              final result = await container
                  .read(explorerActionsProvider)
                  .resumeRestoredPane(paneId);
              final message = result.message;
              if (message != null) {
                messenger.showSnackBar(SnackBar(content: Text(message)));
              }
            },
            onResumeAll: () {
              // Closed first, and then the work: the panes come up over several
              // frames and the point of spreading them is that the user can
              // watch it happen rather than watch a dialog.
              Navigator.of(context).pop();
              _resumeAllRestored(container, messenger);
            },
          );
        },
      ),
    );
  }

  Future<void> _resumeAllRestored(
    ProviderContainer container,
    ScaffoldMessengerState messenger,
  ) async {
    final report = await container
        .read(explorerActionsProvider)
        .resumeAllRestoredPanes();
    final message = report.message;
    if (message == null) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> showCommands(BuildContext context) async {
    final instance = focusedInstance();
    if (instance == null) return;
    final picked = await showDialog<CommandBlock>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Commands'),
        contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
        content: SizedBox(
          width: 560,
          child: CommandHistorySheet(
            blocks: focusedBlocks(),
            onSelect: (block) => Navigator.of(context).pop(block),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (picked != null) scrollPaneTo(instance, picked);
  }

  /// Terminal-wide shortcuts, handled through `TerminalView.onKeyEvent`, which
  /// the widget consults *before* its own shortcut manager and before
  /// `Terminal.keyInput`.
  ///
  /// **This is the only hook the app's own chords have.** Key events reach the
  /// focused node first and bubble *upward*, so no wrapper above `TerminalView`
  /// can see a key before it does — and xterm reports every key as handled,
  /// turning an unclaimed `Ctrl+B` into a literal `^B` and leaving the shell's
  /// ambient [Shortcuts] permanently unreachable from the app's primary
  /// surface. So the pane asks [handleAppChordFromTerminal] — the declared
  /// skip-list, derived from the one shortcut map — and dispatches what it
  /// finds through the same [Actions] the rest of the app uses. One
  /// implementation of "toggle the side panel", reached two ways.
  ///
  /// **And it asks nothing else.** The pane's own verbs — split, find, the
  /// command jumps, the region and focus moves — used to be an `if` chain right
  /// here, which is how `Ctrl+Shift+D/E/F` came to be handled by a chord in no
  /// list, `Ctrl+PageUp` came to ignore the answer the user gave Settings, and
  /// three tooltips came to spell their chords out by hand. They are entries in
  /// `shellChords` now, pane-local ones stay out of the app-wide map, and
  /// `pane_chord_registry_test.dart` fails if this method ever claims a key the
  /// registry has not declared.
  KeyEventResult onPaneKey(FocusNode node, KeyEvent event) {
    // The typing path: every keystroke in a pane arrives here, and only a
    // modified one can be a chord.
    if (!HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    final context = node.context;
    if (context == null) return KeyEventResult.ignored;
    // Claimed for the app, or passed to the process. There is no third
    // answer: reporting `ignored` for a chord the shell owns would let
    // xterm's fallback type it as a control character.
    return handleAppChordFromTerminal(
          context,
          event,
          // Whose chord this is, is the user's call: the declared skip-list
          // is a default and Settings can flip any of it.
          overrides: ref.read(settingsControllerProvider).terminalChordOverrides,
        )
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }
}
