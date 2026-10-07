import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/pane.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart' show keyboardIsSpokenFor;
import 'package:karmashala_ui/tokens.dart';
import '../../notes/application/notes_providers.dart';
import '../../notes/presentation/note_edit_dialog.dart';
import '../../notes/presentation/note_tab_view.dart';
import '../../settings/application/settings_controller.dart';
import '../../editor/presentation/editor_tab_view.dart';
import '../../editor/domain/media_kind.dart';
import '../../editor/presentation/media/media_pane.dart';
import '../../files/presentation/files_tab_view.dart';
import '../../browser/presentation/browser_pane.dart';
import '../application/browser_document_pane.dart';
import '../../git/application/diff_tab_actions.dart';
import '../../git/presentation/diff_tab_view.dart';
import '../../settings/presentation/settings_tab_view.dart';
import '../../agents/presentation/usage_tab/usage_tab_view.dart';
import '../../automations/presentation/automations_tab_view.dart';
import '../../stores/presentation/stores_tab_view.dart';
import '../../../app/shell/logs_tab_view.dart';
import '../../overview/presentation/overview_tab_view.dart';
import '../../../app/shell/running_tab_view.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../sessions/presentation/session_transcript_view.dart';
import '../../todos/presentation/todo_edit_dialog.dart';
import '../../onboarding/presentation/keyboard_map.dart';
import '../application/terminal_capture.dart';
import '../application/terminal_paste.dart';
import 'terminal_copy_text.dart';
import 'terminal_file_drop.dart';
import 'terminal_presence.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/media/video_support_provider.dart';
import '../application/terminal_recording_controller.dart';
import '../application/terminal_theme_controller.dart';
import '../application/terminal_search_controller.dart';
import '../application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../../../app/shell/keymap_controller.dart';
import '../../../app/shell/quick_open/quick_open.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/shell/tab_picker.dart';
import '../../../app/shell/workbench.dart' show CompactWorkbenchScope;
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'dense_icon_button.dart';
import 'empty_pane_region.dart';
import 'pane_frame.dart';
import 'pane_group_strip.dart';
import 'pane_layout_view.dart';
import 'recording_saved_dialog.dart';
import 'terminal_search_bar.dart';
import 'terminal_actions.dart';
import 'terminal_theme_colors.dart';

// Re-exported so this file is still the one import the panel's callers need.
export '../../../app/shell/workbench_tab_chip.dart';

export 'terminal_actions.dart';
export 'terminal_tab_chip.dart';
export 'terminal_theme_colors.dart';

part 'terminal_empty_state.dart';
part 'terminal_pane_drop_target.dart';
part 'terminal_pane_handle.dart';
part 'terminal_pane_menu.dart';
part 'terminal_pane_regions.dart';
part 'terminal_toolbar.dart';

/// The terminal's panes: the search bar over the active tab's split tree. Only
/// [kMountedTabBudget] tabs stay mounted — all of them cost 65 ms a tab switch.
class TerminalPaneStack extends ConsumerStatefulWidget {
  const TerminalPaneStack({this.groupId, this.groupFocused = true, super.key});

  /// The workspace group whose tabs these are, or null while no tab is open.
  final String? groupId;

  /// Only the focused group draws a pane as focused; every group still draws
  /// its own tab.
  final bool groupFocused;

  @override
  ConsumerState<TerminalPaneStack> createState() => _TerminalPaneStackState();
}

class _TerminalPaneStackState extends ConsumerState<TerminalPaneStack> {
  late final TerminalActions _actions = TerminalActions(ref);

  /// The tabs with a mounted view — widget-lifetime state, not layout state.
  /// Publishing it would put a rebuild of every consumer behind every switch.
  final MountedTabs _mounted = MountedTabs();

  TerminalSessionsController get _sessions =>
      ref.read(terminalSessionsControllerProvider.notifier);

  /// The chosen scheme's palette (built-in or imported), or null on Match app
  /// or when a stored theme file no longer resolves.
  TerminalPalette? _schemePalette() => ref.watch(terminalPaletteProvider);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Deliberately narrow: the topology and which tab is in front, not the
    // whole layout. A process exiting changes neither, so it does not rebuild
    // the stack — the pane's own status bar watches its liveness.
    final groupId = widget.groupId;
    final openTabs = groupId == null
        ? ref.watch(terminalTabsProvider)
        : ref.watch(workspaceGroupTabsProvider(groupId));
    final activeTabId = groupId == null
        ? ref.watch(terminalActiveTabIdProvider)
        : ref.watch(workspaceGroupActiveTabProvider(groupId));
    // One search bar, over the group the keyboard is in: it is bound to a pane,
    // and a pane nobody is typing into has nothing to find.
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
                // Nothing opens by itself: a terminal starts a shell on a
                // machine, which only the person may ask for.
                ? _NoTerminalOpen(
                    onNewTerminal: () =>
                        _actions.open(_actions.defaultProfile()),
                  )
                : IndexedStack(
                    index: activeIndex < 0 ? 0 : activeIndex,
                    children: [
                      for (final tab in tabs)
                        PaneLayoutView(
                          // Keyed by tab, so evicting one does not hand its
                          // element to whichever tab shifts into its slot.
                          key: ValueKey(tab.id),
                          layout: tab.layout,
                          // Already a share of the split it belongs to. Pixels over the *panel's*
                          // longest side moved a divider 36 px per 100 in a 1440x560 window.
                          onResize: (splitId, index, share) => _sessions
                              .resizePane(tab.id, splitId, index, share),
                          regionBuilder: (group) => _buildRegion(
                            group,
                            tab,
                            widget.groupFocused && tab.id == activeTabId,
                            // Focused is where typing goes; showing is which
                            // mounted tab the stack paints. Only a document
                            // reads the second — see [_buildPane].
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
