import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_status.dart';
import '../../notes/application/notes_providers.dart';
import '../../notes/presentation/note_edit_dialog.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_tab_view.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../todos/presentation/todo_edit_dialog.dart';
import '../application/terminal_capture.dart';
import '../application/terminal_link_actions.dart';
import '../application/terminal_paste.dart';
import '../../../core/media/video_support_provider.dart';
import '../application/terminal_recording_controller.dart';
import '../application/terminal_theme_controller.dart';
import '../application/terminal_search_controller.dart';
import '../application/terminal_sessions_controller.dart';
import '../data/terminal_instance.dart';
import '../data/theme_discovery.dart';
import '../domain/document_pane.dart';
import '../domain/mounted_tabs.dart';
import '../domain/terminal_drag.dart';
import '../domain/terminal_palette.dart';
import '../domain/pane_layout.dart';
import '../domain/pane_liveness.dart';
import '../domain/pane_restart.dart';
import '../domain/terminal_profile.dart';
import '../../../app/shell/quick_open/quick_open.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/shell/tab_picker.dart';
import '../../../app/shell/workbench_tab_chip.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'empty_pane_region.dart';
import 'pane_group_strip.dart';
import 'pane_layout_view.dart';
import 'session_status.dart';
import 'recording_saved_dialog.dart';
import 'terminal_pane_view.dart';
import 'terminal_search_bar.dart';
import 'terminal_actions.dart';

// The chip shape moved out so a region header could share it; re-exported so
// this file is still the one import a tab chip needs.
export '../../../app/shell/workbench_tab_chip.dart';

// The families that carry no privacy of their own are libraries rather than
// parts, and are re-exported here so this file is still the one import the
// panel's callers need.
export 'terminal_actions.dart';

part 'terminal_pane_regions.dart';

/// The terminal's panes: the search bar over the active tab's split tree.
///
/// A **bounded** set of tabs stays mounted inside an [IndexedStack], which
/// paints only its active child — so a mounted-but-hidden tab costs no painting
/// (the property Loop 26's performance work depends on) and an unmounted tab
/// costs nothing at all.
///
/// The bound is the point. `IndexedStack` is preservation, not virtualization:
/// it was handed every open tab, and each one kept its render objects, layouts
/// and controllers alive for a pane nobody could see — 5 291 render objects and
/// a 65 ms tab switch at 100 tabs. Only the last [kMountedTabBudget] tabs the
/// user touched are built now; the rest are rebuilt on demand, against the same
/// live `TerminalInstance`, so an unmounted tab keeps its process, its buffer
/// and its scrollback and comes back unchanged. See [MountedTabs].
class TerminalPaneStack extends ConsumerStatefulWidget {
  const TerminalPaneStack({
    this.groupId,
    this.groupFocused = true,
    this.autoOpenDone = true,
    super.key,
  });

  /// The workspace group whose tabs these are, or null before the window has
  /// a workspace at all — the one frame between launching and the first tab.
  final String? groupId;

  /// Whether the keyboard is in this group. Only the focused group draws a
  /// pane as focused; every group still draws its own tab.
  final bool groupFocused;

  /// Whether the workbench's one automatic open has had its turn. Owned up
  /// there rather than here: this widget is rebuilt whenever the workspace
  /// gains or loses its last tab, and a flag that resets with it would reopen
  /// the terminal the user has just closed.
  final bool autoOpenDone;

  @override
  ConsumerState<TerminalPaneStack> createState() => _TerminalPaneStackState();
}

class _TerminalPaneStackState extends ConsumerState<TerminalPaneStack> {
  late final TerminalActions _actions = TerminalActions(ref);

  /// The tabs with a mounted view. Widget-lifetime state, not layout state:
  /// which tabs happen to be built is nobody else's business, and publishing it
  /// would put a rebuild of every consumer behind every tab switch.
  final MountedTabs _mounted = MountedTabs();

  TerminalSessionsController get _sessions =>
      ref.read(terminalSessionsControllerProvider.notifier);

  /// The imported palette, or null when the user is on the built-in theme or
  /// the stored theme no longer resolves.
  TerminalPalette? _importedPalette() {
    final result = ref.watch(importedTerminalThemeProvider);
    return result is ThemeLoadOk ? result.palette : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Deliberately narrow: the topology and which tab is in front, not the
    // whole layout. A process exiting changes neither, so it no longer
    // rebuilds the stack — the pane's own status bar watches its liveness.
    final groupId = widget.groupId;
    final openTabs = groupId == null
        ? ref.watch(terminalTabsProvider)
        : ref.watch(workspaceGroupTabsProvider(groupId));
    final activeTabId = groupId == null
        ? ref.watch(terminalActiveTabIdProvider)
        : ref.watch(workspaceGroupActiveTabProvider(groupId));
    // One search bar, over the group the keyboard is in: the bar is bound to a
    // pane, and a pane in a group nobody is typing into has nothing to find.
    final search = ref.watch(terminalSearchControllerProvider);
    _mounted.sync(
      openTabIds: [for (final tab in openTabs) tab.id],
      activeTabId: activeTabId,
    );
    final tabs = [
      for (final tab in openTabs)
        if (_mounted.contains(tab.id)) tab,
    ];
    final activeIndex = tabs.indexWhere((t) => t.id == activeTabId);

    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          if (search.visible && widget.groupFocused) const TerminalSearchBar(),
          Expanded(
            child: openTabs.isEmpty
                ? widget.autoOpenDone
                      ? _NoTerminalOpen(
                          onNewTerminal: () =>
                              _actions.open(_actions.defaultProfile()),
                        )
                      : Center(
                          child: Text(
                            'Opening terminal…',
                            style: theme.textTheme.bodySmall,
                          ),
                        )
                : IndexedStack(
                    index: activeIndex < 0 ? 0 : activeIndex,
                    children: [
                      for (final tab in tabs)
                        PaneLayoutView(
                          // Keyed by tab, so evicting one does not hand its
                          // element to whichever tab shifted into its slot.
                          key: ValueKey(tab.id),
                          layout: tab.layout,
                          // Already a share of the split it belongs to — see
                          // [PaneResizeCallback]. It used to be pixels this
                          // divided by the *panel's* longest side, which is
                          // neither the split's axis nor its box: in a 1440x560
                          // window a top/bottom divider moved 36 px for every
                          // 100 the pointer did.
                          onResize: (splitId, index, share) =>
                              _sessions.resizePane(tab.id, splitId, index, share),
                          regionBuilder: (group) => _buildRegion(
                            group,
                            tab,
                            widget.groupFocused && tab.id == activeTabId,
                            // Focused is where typing goes; showing is which
                            // of the mounted tabs the stack is painting. Only
                            // a document reads the second — see [_buildPane].
                            showing: tab.id == activeTabId,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Ends the recording on [paneId] and offers what can be made from it.
  Future<void> _stopRecording(BuildContext context, String paneId) async {
    await ref.read(terminalRecordingProvider.notifier).stop(paneId);
    if (context.mounted) await showRecordingSavedDialog(context);
  }

  Future<void> _terminalMenu(
    BuildContext context,
    Offset position,
    String paneId,
    TerminalInstance session,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selection = session.controller.selection;
    final hasSelection = selection != null;
    // Read once, as the menu is built, and used by every row that wants it.
    // The two capture rows are only offered for a selection that caught
    // something: a drag over blank cells is not a todo, and a row that opens
    // an empty composer is a row that wasted the click.
    final selected = selection == null
        ? null
        : session.terminal.buffer.getText(selection);
    final capturable = selected != null && selected.trim().isNotEmpty;
    final notesEnabled = ref.read(notesEnabledProvider);
    final recordingThis = ref.read(terminalRecordingProvider).isRecording(paneId);
    // What the recording will be able to become, said before it is started
    // rather than when the export dialog has to refuse.
    final canWriteMp4 = ref.read(videoSupportProvider).available;
    final choice = await showMenu<String>(
      context: context,
      // The same one-pixel anchor `ContextMenuRegion._show` uses, so a menu
      // opened from a pane lands where one opened from the Explorer does.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        DesktopMenuItem(
          value: 'copy',
          label: 'Copy',
          icon: AppIcons.copy,
          shortcut: shellChordLabel<CopySelectionTextIntent>(),
          enabled: hasSelection,
        ),
        DesktopMenuItem(
          value: 'paste',
          label: 'Paste',
          icon: AppIcons.clipboardText,
          shortcut: shellChordLabel<TerminalPasteIntent>(),
        ),
        DesktopMenuItem(
          value: 'find',
          label: 'Find…',
          icon: AppIcons.magnifyingGlass,
          shortcut: shellChordLabel<FindInScrollbackIntent>(),
        ),
        // Keeping what is on screen, in the two places the app already keeps
        // the user's own writing — and the two an agent already reaches through
        // `todo_add` and `note_add`. Offered only with a selection, because
        // unlike Copy there is no disabled version of this that says anything:
        // "create a todo from nothing" is not a lesser act, it is not an act.
        if (capturable) ...[
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'todo',
            label: 'Create todo from selection',
            icon: AppIcons.listChecks,
          ),
          // Absent, not disabled, when Notes is switched off — the one reading
          // `notesEnabledProvider` exists for, so the capture affordance and
          // the surface cannot disagree about whether the user asked for this.
          if (notesEnabled)
            DesktopMenuItem(
              value: 'note',
              label: 'Create note from selection',
              icon: AppIcons.notePencil,
            ),
        ],
        const DesktopMenuDivider(),
        // The *pane* split, and the only place it is offered. The toolbar's two
        // split buttons divide the whole workspace group now — a strip, a
        // surface and a status bar of its own — which is a different act, and
        // one row of chrome cannot honestly stand for both.
        // Recording is a pane's own verb, on the pane's own menu, beside the
        // other one — the same placement rule the split rows below state.
        DesktopMenuItem(
          value: 'record',
          label: recordingThis
              ? 'Stop recording'
              : canWriteMp4
              ? 'Record this pane'
              : 'Record this pane — GIF only, no MP4 here',
          icon: recordingThis ? AppIcons.stopCircle : AppIcons.circle,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'split-pane-right',
          label: 'Split pane right',
          icon: AppIcons.squareSplitHorizontal,
        ),
        DesktopMenuItem(
          value: 'split-pane-down',
          label: 'Split pane down',
          icon: AppIcons.squareSplitVertical,
        ),
        const DesktopMenuDivider(),
        // Only while there is a split to collapse, and only then: with one
        // pane the tab strip's own close button is the way, and two words for
        // one act in two places is how a menu stops being read.
        if (_sessions.isPaneInSplit(paneId)) ...[
          // The way back out of a split, beside the way to close one. The
          // region this pane leaves goes with it — see [movePaneToNewTab].
          DesktopMenuItem(
            value: 'untangle',
            label: 'Move pane to a new tab',
            icon: AppIcons.terminalWindow,
          ),
          DesktopMenuItem(
            value: 'close',
            label: 'Close pane',
            icon: AppIcons.x,
            shortcut: shellChordLabel<CloseTerminalTabIntent>(),
          ),
          const DesktopMenuDivider(),
        ],
        // Closing the tab only detaches; this is how a session actually ends.
        DesktopMenuItem(
          value: 'end',
          label: 'End session',
          icon: AppIcons.power,
          destructive: true,
        ),
      ],
    );
    switch (choice) {
      case 'record':
        if (recordingThis) {
          if (context.mounted) await _stopRecording(context, paneId);
        } else {
          ref.read(terminalRecordingProvider.notifier).start(paneId);
        }
      case 'copy':
        if (selected != null) {
          await Clipboard.setData(ClipboardData(text: selected));
        }
      case 'todo':
        if (selected != null) await _captureTodo(paneId, selected);
      case 'note':
        if (selected != null) await _captureNote(paneId, selected);
      case 'paste':
        // The same rule as the chord, from the same place: a menu item called
        // Paste that silently does nothing with a screenshot on the clipboard
        // is the bug being fixed, not a lesser version of it.
        await pasteIntoTerminal(session.terminal, controller: session.controller);
      case 'find':
        _actions.openSearch();
      case 'split-pane-right':
        _actions.splitPane(SplitAxis.horizontal);
      case 'split-pane-down':
        _actions.splitPane(SplitAxis.vertical);
      case 'untangle':
        _sessions.movePaneToNewTab(paneId);
      case 'close':
        _sessions.closePane(paneId);
      case 'end':
        _sessions.endSession(paneId);
    }
  }

  /// Keeps [selected] as a todo, filed under the pane's project.
  ///
  /// Collapsed to one line **and shown collapsed**, because that is what a
  /// todo is and a terminal selection usually is not — see [todoLineFrom].
  Future<void> _captureTodo(String paneId, String selected) async {
    final source = ref.read(terminalSelectionSourceProvider(paneId));
    final todo = await showNewTodoDialog(
      context,
      ref,
      body: todoLineFrom(selected),
      projectId: source.projectId,
      joinedLines: selectionLineCount(selected),
    );
    if (todo == null || !mounted) return;
    _say('Added to Todos.');
  }

  /// Keeps [selected] as a note, word for word, remembering the session and
  /// repository it was taken from. Nothing is filled in for a plain shell.
  Future<void> _captureNote(String paneId, String selected) async {
    final source = ref.read(terminalSelectionSourceProvider(paneId));
    final note = await showCapturedNoteDialog(
      context,
      ref,
      body: selected,
      projectId: source.projectId,
      sourceSessionId: source.sessionId,
      sourceRepositoryId: source.repositoryId,
    );
    if (note == null || !mounted) return;
    _say('Saved to Notes.');
  }

  /// Confirmation, not navigation: the side panel stays where the user left
  /// it. A right-click in a terminal is not a request to rearrange the window.
  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// One workspace group's own toolbar — find, split, new tab, and the recorded
/// commands button that only appears when it has something to say.
///
/// Sits at the right of that group's tab strip, so a verb that acts on *this*
/// group's focused pane is beside that group's tabs. What is **not** here any
/// more is what was never about one group: the restored-session and
/// background-session badges are questions about the window, and they have
/// gone up to the title bar with focus mode. See [ShellTitleBar].
class TerminalToolbar extends ConsumerWidget {
  const TerminalToolbar({this.compact = false, super.key});

  /// Only the way to make another terminal, for a window too narrow to hold the
  /// rest of the row.
  ///
  /// The other five are a chord and a palette command each, and the two splits
  /// are on the pane's own menu as well — but **the `+` must never be off
  /// screen**. That was true when this row lived in the tab strip ("no number
  /// of tabs can push the way to make another one off the end") and moving the
  /// row up did not stop it being true.
  final bool compact;

  /// Builds of this widget, for `snippet_button_cost_test.dart`.
  ///
  /// The same seam `ShellStatusBar.debugItemBuildCount` and
  /// `ModelChip.debugBuildCount` use, and here for the same reason: this row
  /// sits above a terminal somebody types into all day, and the only way to
  /// keep proving it does not wake for a character is to count it.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugBuildCount++;
    final actions = TerminalActions(ref);
    final hasTabs = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
    );
    final hasCommands = actions.focusedBlocks().isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact && hasCommands)
          IconButton(
            tooltip: 'Commands',
            icon: const Icon(AppIcons.clockCounterClockwise, size: Chrome.icon),
            onPressed: () => actions.showCommands(context),
          ),
        // The saved commands, for whichever pane is in front. Deliberately
        // **unconditional**: it never asks how many snippets there are, so the
        // strip takes out no subscription that a write to the library — or
        // anything else happening while somebody types — could wake. The empty
        // case is answered inside the picker, which always offers "New command
        // snippet…". See `snippet_button_cost_test.dart`.
        if (!compact) IconButton(
          tooltip:
              'Command snippets'
              '${_chord(_snippetChord())}',
          icon: const Icon(AppIcons.bookBookmark, size: Chrome.icon),
          onPressed: hasTabs
              ? () => QuickOpen.show(context, initialQuery: r'$')
              : null,
        ),
        if (!compact) IconButton(
          tooltip:
              'Find in scrollback'
              '${_chord(shellChordLabel<FindInScrollbackIntent>())}',
          icon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
          onPressed: hasTabs ? actions.openSearch : null,
        ),
        if (!compact) IconButton(
          tooltip:
              'Split the workspace right'
              '${_chord(_splitChord(SplitAxis.horizontal))}',
          // `sidebarSimple` means the side panel everywhere else in the
          // chrome; a split is its own shape, and the vertical one no longer
          // needs a RotatedBox to be drawn.
          icon: const Icon(AppIcons.squareSplitHorizontal, size: Chrome.icon),
          onPressed: hasTabs ? () => actions.split(SplitAxis.horizontal) : null,
        ),
        if (!compact) IconButton(
          tooltip:
              'Split the workspace down'
              '${_chord(_splitChord(SplitAxis.vertical))}',
          icon: const Icon(AppIcons.squareSplitVertical, size: Chrome.icon),
          onPressed: hasTabs ? () => actions.split(SplitAxis.vertical) : null,
        ),
        // Two controls, the way VS Code splits them: the button opens the
        // shell you nearly always want, and the caret beside it is where the
        // other ones live. One button that could only ever open a menu made
        // the common case cost a choice.
        IconButton(
          tooltip: 'New terminal${_chord(shellChordLabel<NewTerminalTabIntent>())}',
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          onPressed: () => actions.open(actions.defaultProfile()),
        ),
        PopupMenuButton<TerminalProfile>(
          tooltip: 'New terminal with a different profile',
          icon: const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
          // The caret is a hair beside the +, not a second button's width away.
          constraints: const BoxConstraints(minWidth: 180),
          padding: EdgeInsets.zero,
          iconSize: Chrome.iconSmall,
          onSelected: actions.open,
          itemBuilder: (context) => [
            for (final profile in actions.profiles())
              PopupMenuItem(
                value: profile,
                height: 32,
                child: Row(
                  children: [
                    const Icon(AppIcons.terminal, size: Chrome.icon),
                    const SizedBox(width: 10),
                    Text(profile.label),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// What the panel shows once the user has closed the last terminal.
///
/// A way back, rather than a status. The panel used to say "Opening terminal…"
/// here, which is true for the one frame before the automatic open and a lie
/// for as long as the layout stays closed — and it left the only route back
/// to a terminal in the toolbar, which reads as chrome rather than as the
/// answer to an empty layout.
class _NoTerminalOpen extends StatelessWidget {
  const _NoTerminalOpen({required this.onNewTerminal});

  final VoidCallback onNewTerminal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('No terminal open', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onNewTerminal,
            icon: const Icon(AppIcons.plus, size: Chrome.icon),
            label: Text(
              'New terminal${_chord(shellChordLabel<NewTerminalTabIntent>())}',
            ),
          ),
        ],
      ),
    );
  }
}

/// A chord in a tooltip, or nothing when the action has none.
String _chord(String? label) => label == null ? '' : ' ($label)';

/// The chord that splits along [axis]. Both halves share one intent type, so
/// the axis is what tells `Ctrl+Shift+D` from `Ctrl+Shift+E`.
String? _splitChord(SplitAxis axis) =>
    shellChordLabel<SplitTerminalPaneIntent>(where: (i) => i.axis == axis);

/// The chord that opens quick open already filtered to snippets. Four chords
/// share [OpenQuickOpenIntent], so the seeded query is what tells them apart —
/// the same narrowing the two split chords need.
String? _snippetChord() =>
    shellChordLabel<OpenQuickOpenIntent>(where: (i) => i.query == r'$');

/// A bulk close, named the way VS Code names it.
///
/// Declared in the order the menu lists them, so the rows and this list cannot
/// drift apart, and carrying the three things a row needs — what it is called,
/// what it draws, and which tabs it takes — in one place rather than three.
enum TabCloseScope {
  others('Close others', AppIcons.minusCircle),
  toTheRight('Close to the right', AppIcons.caretRight),
  toTheLeft('Close to the left', AppIcons.caretLeft),
  all('Close all', AppIcons.xCircle);

  const TabCloseScope(this.label, this.icon);

  /// What the menu row says.
  final String label;

  /// What it draws in the row's leading slot.
  final IconData icon;

  /// The tabs this scope closes, for the tab at [index] of [ids].
  List<String> apply(List<String> ids, int index) => switch (this) {
    TabCloseScope.others => [
      for (var i = 0; i < ids.length; i++)
        if (i != index) ids[i],
    ],
    TabCloseScope.toTheRight => ids.sublist(index + 1),
    TabCloseScope.toTheLeft => ids.sublist(0, index),
    TabCloseScope.all => List.of(ids),
  };

  /// Whether it would close anything at all from [index] of [count] tabs.
  ///
  /// A greyed row is better than a live one that silently does nothing: "Close
  /// to the right" on the last tab has to say so rather than swallow the click.
  bool closesAnything(int index, int count) => switch (this) {
    TabCloseScope.others || TabCloseScope.all => count > 1,
    TabCloseScope.toTheRight => index < count - 1,
    TabCloseScope.toTheLeft => index > 0,
  };
}

/// One terminal tab, drawn as a chip in the workbench strip.
class TerminalTabChip extends StatelessWidget {
  const TerminalTabChip({
    required this.title,
    required this.liveness,
    required this.selected,
    required this.index,
    required this.tabCount,
    required this.onTap,
    required this.onClose,
    required this.onEnd,
    required this.onBulkClose,
    this.onSavePreset,
    this.agentStatus,
    this.icon,
    this.accented = true,
    super.key,
  });

  /// How many of these have been built. The seam a cost test counts through:
  /// a status change must redraw the one chip it is about, not the strip.
  @visibleForTesting
  static int debugBuildCount = 0;

  final String title;
  final PaneLiveness liveness;

  /// What the agent in this tab holds is doing, or null when the tab holds no
  /// live agent session — a plain shell, or history with nothing behind it.
  ///
  /// Handed in rather than watched, exactly as [liveness] is: the chip is a
  /// dumb view of one tab and `_TabChip` is what subscribes.
  final AgentActivityStatus? agentStatus;

  /// A glyph in place of the status dot, for a tab whose content is not a
  /// process. A document has no liveness to report and `exited` — the honest
  /// answer for a pane with no instance — would read as a session that died.
  final IconData? icon;

  final bool selected;

  /// Whether this is also the tab the keyboard is in — see
  /// [WorkbenchTabChip.accented] for the three states. Every workspace group
  /// shows which tab it holds; only one of them shows where typing goes.
  final bool accented;

  /// Names and stores the whole workbench's shape. Null where a chip has no
  /// workspace behind it to capture — a preview, or a test.
  final VoidCallback? onSavePreset;

  /// Where this tab sits in the strip, and how many there are.
  ///
  /// The two facts a bulk row needs to know whether it would close anything —
  /// handed in rather than read from a provider, because the chip is a dumb
  /// view of one tab and the strip is the thing that knows the shape of the
  /// row it laid out.
  final int index;
  final int tabCount;

  final VoidCallback onTap;

  /// Closes the tab, leaving anything running in the background.
  final VoidCallback onClose;

  /// Ends the tab's sessions outright. Only ever reached deliberately, from the
  /// tab's context menu — the X is not a kill switch.
  final VoidCallback onEnd;

  /// Runs one of the bulk closes. The confirmation those need is the strip's,
  /// not the chip's: it is the thing that can see which of the tabs it would
  /// close still has a session running.
  final ValueChanged<TabCloseScope> onBulkClose;

  @override
  Widget build(BuildContext context) {
    debugBuildCount++;
    final status = agentStatus;
    return WorkbenchTabChip(
      selected: selected,
      accented: accented,
      onTap: onTap,
      onSecondaryTapDown: (details) => _menu(context, details.globalPosition),
      // Middle click, the same close this tab's X performs — the session keeps
      // running, exactly as that button's tooltip promises.
      onClose: onClose,
      // One slot, never two glyphs: a tab running an agent says what the agent
      // is doing, one that is not says whether anything is running at all, and
      // a document says what it is.
      leading: icon != null
          ? Icon(icon, size: Chrome.iconSmall)
          : status == null
          ? TabLivenessDot(liveness: liveness)
          : TabAgentStatusDot(status: status),
      label: title,
      trailing: IconButton(
        tooltip: liveness.isLive
            ? 'Close tab (the session keeps running)'
            : 'Close tab',
        iconSize: Chrome.iconSmall,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        padding: EdgeInsets.zero,
        icon: const Icon(AppIcons.x),
        onPressed: onClose,
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      // `ContextMenuRegion._show`'s anchor. The chip keeps `showMenu` rather
      // than that widget because the gesture already arrives through
      // [WorkbenchTabChip]'s own `InkWell`, and the strip wraps the chip in a
      // `Draggable` that a second translucent detector would fight.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        // Closing one tab detaches, and says nothing: that is a view action,
        // and the session is still in the background list. The four below are
        // the user clearing the deck, so they ask first — see
        // [confirmBulkTabClose].
        DesktopMenuItem(value: 'close', label: 'Close tab', icon: AppIcons.x),
        for (final scope in TabCloseScope.values)
          DesktopMenuItem(
            value: scope.name,
            label: scope.label,
            icon: scope.icon,
            enabled: scope.closesAnything(index, tabCount),
          ),
        // Not about *this* tab, and here anyway. The strip's own verbs moved to
        // the title bar, and this is the menu a person opens when they are
        // thinking about the shape of their tabs — which is what a preset is.
        if (onSavePreset != null) ...[
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'save-preset',
            label: 'Save this layout as a preset…',
            icon: AppIcons.terminalWindow,
          ),
        ],
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'end',
          label: 'End session',
          icon: AppIcons.power,
          destructive: true,
        ),
      ],
    );
    if (choice == null) return;
    switch (choice) {
      case 'close':
        onClose();
      case 'end':
        onEnd();
      case 'save-preset':
        onSavePreset?.call();
      default:
        onBulkClose(TabCloseScope.values.byName(choice));
    }
  }
}

/// The terminal's colours: xterm's own 16-colour palette, with the background,
/// foreground and cursor aligned to the app surface so the panel reads as one
/// piece. An imported theme brings its own background and wins.
TerminalTheme terminalThemeFor(ThemeData theme, TerminalPalette? imported) {
  final scheme = theme.colorScheme;
  final base = TerminalThemes.defaultTheme.copyWith(
    background: scheme.surfaceContainerLowest,
    foreground: scheme.onSurface,
    cursor: scheme.primary,
  );
  // The user picked those colours deliberately, so they win over the app
  // surface.
  return imported?.applyTo(base) ?? base;
}

extension on TerminalTheme {
  TerminalTheme copyWith({
    Color? background,
    Color? foreground,
    Color? cursor,
  }) {
    return TerminalTheme(
      cursor: cursor ?? this.cursor,
      selection: selection,
      foreground: foreground ?? this.foreground,
      background: background ?? this.background,
      black: black,
      red: red,
      green: green,
      yellow: yellow,
      blue: blue,
      magenta: magenta,
      cyan: cyan,
      white: white,
      brightBlack: brightBlack,
      brightRed: brightRed,
      brightGreen: brightGreen,
      brightYellow: brightYellow,
      brightBlue: brightBlue,
      brightMagenta: brightMagenta,
      brightCyan: brightCyan,
      brightWhite: brightWhite,
      searchHitBackground: searchHitBackground,
      searchHitBackgroundCurrent: searchHitBackgroundCurrent,
      searchHitForeground: searchHitForeground,
    );
  }
}

enum _SplitDropZone { left, right, top, bottom }

/// A drop target over an active terminal pane that allows splitting the pane
/// horizontally or vertically by dragging another tab or pane over it.
class _PaneDropTarget extends ConsumerStatefulWidget {
  const _PaneDropTarget({
    required this.paneId,
    required this.groupId,
    required this.child,
  });

  final String paneId;

  /// The workspace group this pane is in. A **tab** dropped on an edge divides
  /// that group and lands in the new one; a **pane** divides the tab, which is
  /// what a region is for. See
  /// [TerminalSessionsController.moveTabBesideGroup].
  final String? groupId;

  final Widget child;

  @override
  ConsumerState<_PaneDropTarget> createState() => _PaneDropTargetState();
}

class _PaneDropTargetState extends ConsumerState<_PaneDropTarget> {
  _SplitDropZone? _activeZone;

  void _updateZone(Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0 && box.size.height > 0) {
      final local = box.globalToLocal(globalPos);
      final dx = (local.dx / box.size.width).clamp(0.0, 1.0);
      final dy = (local.dy / box.size.height).clamp(0.0, 1.0);
      final distH = (dx - 0.5).abs();
      final distV = (dy - 0.5).abs();
      final zone = distH >= distV
          ? (dx < 0.5 ? _SplitDropZone.left : _SplitDropZone.right)
          : (dy < 0.5 ? _SplitDropZone.top : _SplitDropZone.bottom);
      if (zone != _activeZone) {
        setState(() => _activeZone = zone);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        final group = widget.groupId;
        final accepts = switch (data) {
          TabDrag(:final tabId) =>
            group != null && sessions.canMoveTabBesideGroup(tabId, group),
          PaneDrag(:final paneId) =>
            sessions.canSplitPaneWithPane(widget.paneId, paneId),
        };
        if (accepts) {
          _updateZone(details.offset);
        }
        return accepts;
      },
      onMove: (details) => _updateZone(details.offset),
      onLeave: (_) {
        if (mounted && _activeZone != null) {
          setState(() => _activeZone = null);
        }
      },
      onAcceptWithDetails: (details) {
        final zone = _activeZone ?? _SplitDropZone.right;
        final axis = (zone == _SplitDropZone.left || zone == _SplitDropZone.right)
            ? SplitAxis.horizontal
            : SplitAxis.vertical;
        final insertBefore =
            (zone == _SplitDropZone.left || zone == _SplitDropZone.top);

        switch (details.data) {
          case TabDrag(:final tabId):
            if (widget.groupId case final group?) {
              sessions.moveTabBesideGroup(
                tabId,
                group,
                axis,
                insertBefore: insertBefore,
              );
            }
          case PaneDrag(:final paneId):
            sessions.splitPaneWithPane(
              widget.paneId,
              paneId,
              axis,
              insertBefore: insertBefore,
            );
        }
        if (mounted) setState(() => _activeZone = null);
      },
      builder: (context, candidate, _) {
        if (candidate.isEmpty || _activeZone == null) {
          return widget.child;
        }

        final theme = Theme.of(context);
        final isHorizontal =
            _activeZone == _SplitDropZone.left || _activeZone == _SplitDropZone.right;

        return Stack(
          children: [
            widget.child,
            Positioned.fill(
              child: Align(
                alignment: switch (_activeZone!) {
                  _SplitDropZone.left => Alignment.centerLeft,
                  _SplitDropZone.right => Alignment.centerRight,
                  _SplitDropZone.top => Alignment.topCenter,
                  _SplitDropZone.bottom => Alignment.bottomCenter,
                },
                child: FractionallySizedBox(
                  widthFactor: isHorizontal ? 0.5 : 1.0,
                  heightFactor: isHorizontal ? 1.0 : 0.5,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.18),
                        border: Border.all(
                          color: theme.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Insets.sm,
                            vertical: Insets.xs,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(Radii.sm),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isHorizontal
                                    ? AppIcons.squareSplitHorizontal
                                    : AppIcons.squareSplitVertical,
                                size: Chrome.iconSmall,
                                color: theme.colorScheme.onPrimary,
                              ),
                              const SizedBox(width: Insets.xs),
                              Text(
                                'Drop to split',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The grip a split pane is dragged out by, so a test can aim at it.
///
/// Named rather than found by geometry for the reason [kTabStripEmptySpace] is:
/// the handle *is* the subject of the gesture.
Key paneDragHandleKey(String paneId) => ValueKey('pane-handle/$paneId');

/// The floating handle in the top-right corner of a split pane: a grip to drag
/// the pane by, and the two verbs that used to live in a per-region header.
///
/// A region of a split no longer draws a header (see [_buildRegion]), so this
/// is the pane's only handle — including the grip that starts a [PaneDrag],
/// which is what still lets a pane be dropped on the tab strip to become a tab,
/// on another region's header to join it, or on another pane to re-split.
class _PaneFloatingActions extends ConsumerStatefulWidget {
  const _PaneFloatingActions({
    required this.paneId,
    required this.focused,
    required this.onMoveToNewTab,
    required this.onClose,
  });

  final String paneId;
  final bool focused;
  final VoidCallback onMoveToNewTab;
  final VoidCallback onClose;

  @override
  ConsumerState<_PaneFloatingActions> createState() =>
      _PaneFloatingActionsState();
}

class _PaneFloatingActionsState extends ConsumerState<_PaneFloatingActions> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final opacity = _hovered ? 1.0 : (widget.focused ? 0.35 : 0.0);
    final title = ref.watch(terminalPaneTitleProvider(widget.paneId));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 150),
        // Invisible is also unclickable: the box stays to keep the hover
        // target and the geometry the same in every state.
        child: IgnorePointer(
          ignoring: opacity == 0.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Draggable<TerminalDrag>(
                  key: paneDragHandleKey(widget.paneId),
                  data: PaneDrag(widget.paneId),
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  feedback: PaneDragFeedback(title: title),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Tooltip(
                      message: 'Drag the pane elsewhere',
                      child: SizedBox(
                        width: 16,
                        height: 22,
                        child: Icon(
                          AppIcons.dotsSixVertical,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Move pane to a new tab',
                  iconSize: Chrome.iconSmall,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    AppIcons.terminalWindow,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onMoveToNewTab,
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Close pane',
                  iconSize: Chrome.iconSmall,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    AppIcons.x,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

