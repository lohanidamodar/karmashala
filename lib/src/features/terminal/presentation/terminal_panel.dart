import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_status.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../sessions/presentation/new_session_dialog.dart';
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
import 'command_history_sheet.dart';
import 'empty_pane_region.dart';
import 'pane_group_strip.dart';
import 'pane_layout_view.dart';
import 'session_status.dart';
import 'terminal_pane_view.dart';
import 'terminal_search_bar.dart';
import '../application/terminal_profiles.dart';

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

  /// The tabs with a mounted view. Widget-lifetime state, not layout state:
  /// which tabs happen to be built is nobody else's business, and publishing it
  /// would put a rebuild of every consumer behind every tab switch.
  final MountedTabs _mounted = MountedTabs();

  /// Whether the one automatic open below has had its turn.
  ///
  /// It runs once, when the panel mounts. Before it, "no tabs" really does mean
  /// a terminal is on its way and saying so is honest; after it, "no tabs" can
  /// only be the user having closed the last one, and the same words became a
  /// message that never changed — the panel sat on "Opening terminal…" with
  /// nothing opening.
  bool _autoOpenDone = false;

  @override
  void initState() {
    super.initState();
    // Ensure there is always at least one terminal when the panes are shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(terminalSessionsControllerProvider).isEmpty) {
        _actions.open(_actions.defaultProfile());
      }
      // Deliberately not conditional on having opened anything: what this
      // records is that the automatic attempt is over, so a layout that
      // stays empty offers the user the button instead of a false promise.
      setState(() => _autoOpenDone = true);
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
    // whole layout. A process exiting changes neither, so it no longer
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
                ? _autoOpenDone
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
    if (empty || group.panes.length < 2) return pane;
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
        onNewSession: () => NewSessionDialog.show(
          context,
          targetPaneId: paneId,
        ),
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

    final paneWidget = GestureDetector(
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
                // The pane's *current* instance for the same reason the view
                // below takes one: a restart replaces it, and a bar quoting the
                // released one would name the directory of the session before
                // last if the new process also stopped.
                final live =
                    ref.watch(terminalPaneInstanceProvider(paneId)) ?? instance;
                return PaneStatusBar(
                  liveness: liveness,
                  workingDirectory: live.workingDirectory,
                  resumes: shouldResumeRatherThanRestart(
                    liveness: liveness,
                    isAgentPane: live.agentLaunch != null,
                  ),
                  onStart: () => _actions.startOrResumePane(context, paneId),
                );
              },
            ),
            Expanded(
              // In its own `Consumer`, watching *which object* is behind this
              // pane, for the same reason the status bar above has one: the
              // stack's own watch is the tab topology, and starting a pane
              // moves neither the tabs nor which one is in front. So the swap
              // `startPane` performs — release the instance, adopt a new one
              // with a new `Terminal`, `FocusNode` and `ScrollController` —
              // was invisible from up there, and the pane went on rendering
              // the instance that had just been disposed. See
              // [terminalPaneInstanceProvider] for what that looked like from
              // the focus node's side, and why the pane came back typable only
              // when something else happened to rebuild the stack.
              //
              // Falling back to [instance] rather than dropping the pane:
              // `_buildPane` has already established there is one, and the
              // provider can only disagree while a rebuild is in flight.
              child: Consumer(
                builder: (context, ref, _) {
                  final live =
                      ref.watch(terminalPaneInstanceProvider(paneId)) ??
                      instance;
                  return TerminalPaneView(
                    // Starting a pane swaps its instance in place; without a
                    // key the element would be reused and keep the disposed
                    // focus node.
                    key: ObjectKey(live),
                    instance: live,
                    focused: focused,
                    fontSize: fontSize,
                    terminalTheme: terminalThemeFor(theme, _importedPalette()),
                    chordOverrides: chordOverrides,
                    onKeyEvent: _actions.onPaneKey,
                    // Right-click → copy selection / paste / end the session.
                    onSecondaryTapDown: (position) =>
                        _terminalMenu(context, position, paneId, live),
                    linkActions: ref.read(terminalLinkActionsProvider),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    final paneWithActions = Stack(
      children: [
        Positioned.fill(child: paneWidget),
        if (showFocusRing)
          Positioned(
            top: Insets.xs,
            right: Insets.xs,
            child: _PaneFloatingActions(
              paneId: paneId,
              focused: focused,
              onMoveToNewTab: () => _sessions.movePaneToNewTab(paneId),
              onClose: () => _sessions.closePane(paneId),
            ),
          ),
      ],
    );

    return _PaneDropTarget(
      paneId: paneId,
      child: paneWithActions,
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
    final backgroundCount = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.detached.length),
    );
    final hasTabs = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
    );
    // Only the number, through a `select`, for the reason the background count
    // is read the same way: this row sits above a terminal somebody types into
    // all day and must not wake for anything smaller than a change it draws.
    final restoredCount = ref.watch(
      restoredAgentPanesProvider.select((panes) => panes.length),
    );
    final hasCommands = actions.focusedBlocks().isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Conditional, like the background badge beside it and unlike the
        // snippets button — a control that is always here is one the tab strip
        // has to find room for at every window width, and `workbench.dart`
        // records what adding an unconditional one to this end cost: 8.8px of
        // overflow at 640 wide. There is also nothing to say when a restart
        // left nothing dormant, which is nearly always.
        if (restoredCount > 0)
          IconButton(
            tooltip:
                '$restoredCount restored session'
                '${restoredCount == 1 ? '' : 's'} — nothing running in '
                '${restoredCount == 1 ? 'it' : 'them'}',
            icon: Badge.count(
              count: restoredCount,
              backgroundColor: Theme.of(context).colorScheme.primary,
              textColor: Theme.of(context).colorScheme.onPrimary,
              // Not the history clock the Commands button beside it uses: two
              // identical icons in one row are one icon as far as the eye is
              // concerned. This one is about starting them again.
              child: const Icon(AppIcons.playCircle, size: Chrome.icon),
            ),
            onPressed: () => actions.showRestoredSessions(context),
          ),
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
        // The saved commands, for whichever pane is in front. Deliberately
        // **unconditional**: it never asks how many snippets there are, so the
        // strip takes out no subscription that a write to the library — or
        // anything else happening while somebody types — could wake. The empty
        // case is answered inside the picker, which always offers "New command
        // snippet…". See `snippet_button_cost_test.dart`.
        IconButton(
          tooltip:
              'Command snippets'
              '${_chord(_snippetChord())}',
          icon: const Icon(AppIcons.bookBookmark, size: Chrome.icon),
          onPressed: hasTabs
              ? () => QuickOpen.show(context, initialQuery: r'$')
              : null,
        ),
        IconButton(
          tooltip:
              'Find in scrollback'
              '${_chord(shellChordLabel<FindInScrollbackIntent>())}',
          icon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
          onPressed: hasTabs ? actions.openSearch : null,
        ),
        IconButton(
          tooltip: 'Split right${_chord(_splitChord(SplitAxis.horizontal))}',
          // `sidebarSimple` means the side panel everywhere else in the
          // chrome; a split is its own shape, and the vertical one no longer
          // needs a RotatedBox to be drawn.
          icon: const Icon(AppIcons.squareSplitHorizontal, size: Chrome.icon),
          onPressed: hasTabs ? () => actions.split(SplitAxis.horizontal) : null,
        ),
        IconButton(
          tooltip: 'Split down${_chord(_splitChord(SplitAxis.vertical))}',
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
    this.agentStatus,
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

  final bool selected;

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
      onTap: onTap,
      onSecondaryTapDown: (details) => _menu(context, details.globalPosition),
      // One slot, never two glyphs: a tab running an agent says what the agent
      // is doing, and one that is not says whether anything is running at all.
      leading: status == null
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
    required this.child,
  });

  final String paneId;
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
        final accepts = switch (data) {
          TabDrag(:final tabId) =>
            sessions.canSplitPaneWithTab(widget.paneId, tabId),
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
            sessions.splitPaneWithTab(
              widget.paneId,
              tabId,
              axis,
              insertBefore: insertBefore,
            );
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

