import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/domain/environment_kind.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../application/terminal_link_actions.dart';
import '../application/terminal_paste.dart';
import '../application/terminal_scroll.dart';
import '../application/terminal_theme_controller.dart';
import '../application/terminal_search_controller.dart';
import '../application/terminal_sessions_controller.dart';
import '../data/terminal_instance.dart';
import '../data/theme_discovery.dart';
import '../domain/command_blocks.dart';
import '../domain/mounted_tabs.dart';
import '../domain/terminal_palette.dart';
import '../domain/pane_layout.dart';
import '../domain/pane_liveness.dart';
import '../domain/terminal_profile.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/shell/tab_picker.dart';
import '../../../app/shell/workbench_tab_chip.dart';
import 'command_history_sheet.dart';
import 'empty_pane_region.dart';
import 'pane_group_strip.dart';
import 'pane_layout_view.dart';
import 'session_status.dart';
import 'terminal_pane_view.dart';
import 'terminal_search_bar.dart';

// The chip shape moved out so a region header could share it; re-exported so
// this file is still the one import a tab chip needs.
export '../../../app/shell/workbench_tab_chip.dart';

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

  List<TerminalProfile> profiles() =>
      terminalProfilesFor(ref.read(environmentsControllerProvider));

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
    if (profile.shell == TerminalShell.wsl) return repo.path.path;
    return repoIsWindows ? repo.path.path : null;
  }

  void open(TerminalProfile profile) {
    _sessions.openTab(profile, workingDirectory: workingDirFor(profile));
  }

  /// Divides the focused pane, leaving the new region empty for the user to
  /// fill — see [TerminalSessionsController.splitPane].
  void split(SplitAxis axis) => _sessions.splitPane(axis);

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
  /// The pane's own verbs are all `Ctrl+Shift+*` because `Ctrl+D`, `Ctrl+E`,
  /// `Ctrl+F` and `Ctrl+W` are live control characters a shell expects to
  /// receive.
  ///
  /// **This is also the only hook the app's own chords have.** Key events reach
  /// the focused node first and bubble *upward*, so no wrapper above
  /// `TerminalView` can see a key before it does — and xterm reports every key
  /// as handled, turning an unclaimed `Ctrl+B` into a literal `^B` and leaving
  /// the shell's ambient [Shortcuts] permanently unreachable from the app's
  /// primary surface. So the pane asks [handleAppChordFromTerminal] — the
  /// declared skip-list, derived from the one shortcut map — and dispatches
  /// what it finds through the same [Actions] the rest of the app uses. One
  /// implementation of "toggle the side panel", reached two ways.
  KeyEventResult onPaneKey(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final shift = keyboard.isShiftPressed;
    final alt = keyboard.isAltPressed;

    void Function()? action;
    if (shift && !alt) {
      if (key == LogicalKeyboardKey.keyD) {
        action = () => split(SplitAxis.horizontal);
      } else if (key == LogicalKeyboardKey.keyE) {
        action = () => split(SplitAxis.vertical);
      } else if (key == LogicalKeyboardKey.keyW) {
        action = closeFocusedPane;
      } else if (key == LogicalKeyboardKey.keyF) {
        action = openSearch;
      } else if (key == LogicalKeyboardKey.keyT) {
        action = () => open(defaultProfile());
      } else if (key == LogicalKeyboardKey.arrowUp) {
        action = () => jumpCommand(forward: false);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        action = () => jumpCommand(forward: true);
      }
    } else if (alt && !shift) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        action = () => _sessions.movePaneFocus(PaneDirection.left);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        action = () => _sessions.movePaneFocus(PaneDirection.right);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        action = () => _sessions.movePaneFocus(PaneDirection.up);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        action = () => _sessions.movePaneFocus(PaneDirection.down);
      }
    } else if (!shift && !alt) {
      if (key == LogicalKeyboardKey.pageUp) {
        action = _sessions.previousTab;
      } else if (key == LogicalKeyboardKey.pageDown) {
        action = _sessions.nextTab;
      }
    }

    // The pane's own verbs win; then the app's skip-list. Nothing overlaps
    // today, and ordering it this way keeps it that way — a chord the pane
    // owns cannot be taken from it by a later addition to the shell map.
    if (action == null) {
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
            overrides: ref
                .read(settingsControllerProvider)
                .terminalChordOverrides,
          )
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    // Act once, on the down event, but swallow the matching up/repeat too so a
    // consumed combo cannot leak a character through xterm's fallback.
    if (event is KeyDownEvent) action();
    return KeyEventResult.handled;
  }
}

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
  const TerminalPaneStack({super.key});

  @override
  ConsumerState<TerminalPaneStack> createState() => _TerminalPaneStackState();
}

class _TerminalPaneStackState extends ConsumerState<TerminalPaneStack> {
  late final TerminalActions _actions = TerminalActions(ref);

  /// The tabs with a mounted view. Widget-lifetime state, not workspace state:
  /// which tabs happen to be built is nobody else's business, and publishing it
  /// would put a rebuild of every consumer behind every tab switch.
  final MountedTabs _mounted = MountedTabs();

  @override
  void initState() {
    super.initState();
    // Ensure there is always at least one terminal when the panes are shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(terminalSessionsControllerProvider).isEmpty) {
        _actions.open(_actions.defaultProfile());
      }
    });
  }

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
    // whole workspace. A process exiting changes neither, so it no longer
    // rebuilds the stack — the pane's own status bar watches its liveness.
    final openTabs = ref.watch(terminalTabsProvider);
    final activeTabId = ref.watch(terminalActiveTabIdProvider);
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
          if (search.visible) const TerminalSearchBar(),
          Expanded(
            child: openTabs.isEmpty
                ? Center(
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
                          onResize: (splitId, index, delta) =>
                              _resize(tab, splitId, index, delta),
                          regionBuilder: (group) =>
                              _buildRegion(group, tab, tab.id == activeTabId),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Turns a pixel drag into a share of the split's own extent.
  void _resize(TerminalTab tab, String splitId, int index, double delta) {
    final box = context.findRenderObject() as RenderBox?;
    final extent = box == null ? 0.0 : box.size.longestSide;
    if (extent <= 0) return;
    _sessions.resizePane(tab.id, splitId, index, delta / extent);
  }

  /// One region: its header, and the one pane it is showing.
  ///
  /// **Only the front pane is built.** A region is a stack, and building the
  /// ones behind it would put their render objects, layouts and controllers on
  /// screen's budget for something nobody can see — the same eager-`IndexedStack`
  /// mistake [MountedTabs] exists to undo one level up. The instance behind a
  /// hidden pane is untouched, so bringing it forward costs a build and nothing
  /// else: its buffer, its scrollback and its process were never its widget's.
  ///
  /// **The header is skipped where it would say nothing.** One region holding
  /// one pane is already named by the workbench strip, and an empty region
  /// draws its own invitation with its own close button — 30px of chrome
  /// repeating either would be 30px taken from the terminal for nothing.
  Widget _buildRegion(PaneGroup group, TerminalTab tab, bool tabActive) {
    final split = tab.layout.groups.length > 1;
    final empty =
        group.panes.length == 1 &&
        _sessions.instanceFor(group.activePaneId) == null;
    final pane = _buildPane(
      group.activePaneId,
      focused: tabActive && group.activePaneId == tab.focusedPaneId,
      showFocusRing: split,
    );
    if (empty || (!split && group.panes.length < 2)) return pane;
    return Column(
      children: [
        PaneGroupStrip(
          group: group,
          focused: tabActive && group.panes.contains(tab.focusedPaneId),
        ),
        Expanded(child: pane),
      ],
    );
  }

  Widget _buildPane(
    String paneId, {
    required bool focused,
    required bool showFocusRing,
  }) {
    final theme = Theme.of(context);
    final instance = _sessions.instanceFor(paneId);
    // A pane a layout holds and the controller has no instance for is an empty
    // region of a split — the invariant `isEmptySlot` states. It is the only
    // way this can be null, so it is the empty state rather than nothing.
    if (instance == null) {
      return EmptyPaneRegion(
        paneId: paneId,
        focused: focused,
        onNewTerminal: () => _actions.openInSlot(paneId),
        onClose: () => _sessions.closePane(paneId),
        onMoveTabHere: _canMoveATabHere(paneId)
            ? () => TabPicker.show(
                context,
                (ref) => tabsMovableInto(ref, paneId),
              )
            : null,
      );
    }
    final fontSize = ref.watch(
      settingsControllerProvider.select((s) => s.terminalFontSize),
    );
    final chordOverrides = ref.watch(
      settingsControllerProvider.select((s) => s.terminalChordOverrides),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => _sessions.focusPane(paneId),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: showFocusRing
              ? Border.all(
                  color: focused
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                )
              : null,
        ),
        child: Column(
          children: [
            // A pane with no process behind it says so, rather than presenting
            // an old prompt as a live one. In its own `Consumer` so a process
            // exiting rebuilds this bar and nothing else.
            Consumer(
              builder: (context, ref, _) {
                final liveness = ref.watch(
                  terminalPaneLivenessProvider(paneId),
                );
                if (liveness.isLive) return const SizedBox.shrink();
                return PaneStatusBar(
                  liveness: liveness,
                  workingDirectory: instance.workingDirectory,
                  onStart: () => _sessions.startPane(paneId),
                );
              },
            ),
            Expanded(
              child: TerminalPaneView(
                // Starting a pane swaps its instance in place; without a key
                // the element would be reused and keep the disposed focus node.
                key: ObjectKey(instance),
                instance: instance,
                focused: focused,
                fontSize: fontSize,
                terminalTheme: terminalThemeFor(theme, _importedPalette()),
                chordOverrides: chordOverrides,
                onKeyEvent: _actions.onPaneKey,
                // Right-click → copy selection / paste / end the session.
                onSecondaryTapDown: (position) =>
                    _terminalMenu(context, position, paneId, instance),
                linkActions: ref.read(terminalLinkActionsProvider),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether any tab could be moved into the empty region [paneId] — false
  /// while it is the only tab there is, when the offer would lead nowhere.
  bool _canMoveATabHere(String paneId) {
    final tabs = ref.read(terminalSessionsControllerProvider).tabs;
    return tabs.any((tab) => _sessions.canMoveTabIntoSlot(tab.id, paneId));
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
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: const Text('Copy'),
        ),
        const PopupMenuItem(value: 'paste', child: Text('Paste')),
        const PopupMenuItem(value: 'find', child: Text('Find…')),
        const PopupMenuDivider(),
        // Only while there is a split to collapse, and only then: with one
        // pane the tab strip's own close button is the way, and two words for
        // one act in two places is how a menu stops being read.
        if (_sessions.isPaneInSplit(paneId)) ...[
          // The way back out of a split, beside the way to close one. The
          // region this pane leaves goes with it — see [movePaneToNewTab].
          const PopupMenuItem(
            value: 'untangle',
            child: Text('Move pane to a new tab'),
          ),
          const PopupMenuItem(value: 'close', child: Text('Close pane')),
        ],
        // Closing the tab only detaches; this is how a session actually ends.
        const PopupMenuItem(value: 'end', child: Text('End session')),
      ],
    );
    switch (choice) {
      case 'copy':
        if (selection != null) {
          final text = session.terminal.buffer.getText(selection);
          await Clipboard.setData(ClipboardData(text: text));
        }
      case 'paste':
        // The same rule as the chord, from the same place: a menu item called
        // Paste that silently does nothing with a screenshot on the clipboard
        // is the bug being fixed, not a lesser version of it.
        await pasteIntoTerminal(session.terminal, controller: session.controller);
      case 'find':
        _actions.openSearch();
      case 'untangle':
        _sessions.movePaneToNewTab(paneId);
      case 'close':
        _sessions.closePane(paneId);
      case 'end':
        _sessions.endSession(paneId);
    }
  }
}

/// The terminal's own toolbar buttons — find, split, new tab and the two
/// buttons that only appear when they have something to say (background
/// sessions, recorded commands).
///
/// Sits at the right of the workbench's tab strip, so terminal verbs stay
/// beside terminal tabs.
class TerminalToolbar extends ConsumerWidget {
  const TerminalToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = TerminalActions(ref);
    final backgroundCount = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.detached.length),
    );
    final hasTabs = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
    );
    final hasCommands = actions.focusedBlocks().isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (backgroundCount > 0)
          IconButton(
            tooltip:
                '$backgroundCount session'
                '${backgroundCount == 1 ? '' : 's'} running in the background',
            // The accent, not Material's default error red: a session running
            // without a tab is the app working as designed, not a fault.
            icon: Badge.count(
              count: backgroundCount,
              backgroundColor: Theme.of(context).colorScheme.primary,
              textColor: Theme.of(context).colorScheme.onPrimary,
              child: const Icon(AppIcons.terminalWindow, size: Chrome.icon),
            ),
            onPressed: () => actions.showBackgroundSessions(context),
          ),
        if (hasCommands)
          IconButton(
            tooltip: 'Commands',
            icon: const Icon(AppIcons.clockCounterClockwise, size: Chrome.icon),
            onPressed: () => actions.showCommands(context),
          ),
        IconButton(
          tooltip: 'Find in scrollback (Ctrl+Shift+F)',
          icon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
          onPressed: hasTabs ? actions.openSearch : null,
        ),
        IconButton(
          tooltip: 'Split right (Ctrl+Shift+D)',
          // `sidebarSimple` means the side panel everywhere else in the
          // chrome; a split is its own shape, and the vertical one no longer
          // needs a RotatedBox to be drawn.
          icon: const Icon(AppIcons.squareSplitHorizontal, size: Chrome.icon),
          onPressed: hasTabs ? () => actions.split(SplitAxis.horizontal) : null,
        ),
        IconButton(
          tooltip: 'Split down (Ctrl+Shift+E)',
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

/// A chord in a tooltip, or nothing when the action has none.
String _chord(String? label) => label == null ? '' : ' ($label)';

/// One terminal tab, drawn as a chip in the workbench strip.
class TerminalTabChip extends StatelessWidget {
  const TerminalTabChip({
    required this.title,
    required this.liveness,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onEnd,
    super.key,
  });

  final String title;
  final PaneLiveness liveness;
  final bool selected;
  final VoidCallback onTap;

  /// Closes the tab, leaving anything running in the background.
  final VoidCallback onClose;

  /// Ends the tab's sessions outright. Only ever reached deliberately, from the
  /// tab's context menu — the X is not a kill switch.
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return WorkbenchTabChip(
      selected: selected,
      onTap: onTap,
      onSecondaryTapDown: (details) => _menu(context, details.globalPosition),
      leading: TabLivenessDot(liveness: liveness),
      label: title,
      trailing: IconButton(
        tooltip: liveness.isLive
            ? 'Close tab (the session keeps running)'
            : 'Close tab',
        iconSize: 13,
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
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'close',
          child: Text('Close tab, keep running'),
        ),
        const PopupMenuItem(value: 'end', child: Text('End session')),
      ],
    );
    switch (choice) {
      case 'close':
        onClose();
      case 'end':
        onEnd();
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
