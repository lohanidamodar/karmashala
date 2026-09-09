import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'terminal_theme_colors.dart';

// The chip shape moved out so a region header could share it; re-exported so
// this file is still the one import a tab chip needs.
export '../../../app/shell/workbench_tab_chip.dart';

// The families that carry no privacy of their own are libraries rather than
// parts, and are re-exported here so this file is still the one import the
// panel's callers need.
export 'terminal_actions.dart';
export 'terminal_tab_chip.dart';
export 'terminal_theme_colors.dart';

part 'terminal_empty_state.dart';
part 'terminal_pane_drop_target.dart';
part 'terminal_pane_handle.dart';
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
