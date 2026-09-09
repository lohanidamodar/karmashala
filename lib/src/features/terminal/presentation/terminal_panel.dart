import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
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
import '../domain/pane_restart.dart';
import '../domain/terminal_profile.dart';
import '../../../app/shell/quick_open/quick_open.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/shell/tab_picker.dart';
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
export 'terminal_tab_chip.dart';

part 'terminal_pane_drop_target.dart';
part 'terminal_pane_menu.dart';
part 'terminal_pane_regions.dart';
part 'terminal_toolbar.dart';

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
