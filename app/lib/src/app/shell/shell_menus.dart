import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/system/system_integration_service.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_actions.dart';
import 'karmashala_about_dialog.dart';
import 'quick_open/quick_open.dart';
import 'shell_menu_items.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';
import 'workbench_tabs.dart';

/// What the menus do, bound to the widget that **hosts** them. A menu item's
/// own context is unmounted by the time `onPressed` runs — the menu closes
/// first — so a dialog or a provider read has to go through the host's.
class ShellMenuActions {
  const ShellMenuActions(this._context, this._ref);

  final BuildContext _context;
  final WidgetRef _ref;

  void newProject() => NewProjectDialog.show(_context);

  // Never disabled: the dialog chooses where the session runs, so it no longer
  // needs the app to be pointed anywhere first.
  void newSession() => NewSessionDialog.show(_context);

  void goTo() => QuickOpen.show(_context);

  void detectCliSessions() => DetectedProjectsView.show(_context);

  // The real exit, whatever close-to-tray does to the window: the tray's own
  // Quit, so shutdown runs in order either way.
  void quit() {
    final system = _ref.read(systemIntegrationProvider);
    if (system != null) unawaited(system.quit());
  }

  void toggleSidebar() =>
      _ref.read(shellControllerProvider.notifier).toggleExplorerPane();

  void toggleSidePanel() => _ref.read(sidePanelProvider.notifier).toggle();

  /// What pressing one of the context panel's tabs does: opens it, never
  /// closes it.
  void showContextTab(ContextTab tab) =>
      _ref.read(sidePanelProvider.notifier).showTab(tab);

  /// What picking a surface from the panel's More menu does.
  void showSurface(SidePanelSurface surface) =>
      _ref.read(sidePanelProvider.notifier).show(surface);

  void toggleFocusMode() =>
      _ref.read(terminalMaximizedProvider.notifier).toggle();

  /// Whether there is a terminal for the Terminal verbs to act on.
  bool get hasTerminal =>
      _ref.read(terminalSessionsControllerProvider).tabs.isNotEmpty;

  void findInScrollback() => TerminalActions(_ref).openSearch();

  void commandSnippets() => QuickOpen.show(_context, initialQuery: r'$');

  void commandsRun() => TerminalActions(_ref).showCommands(_context);

  void openSettings() => openSettingsTab(_ref);

  void about() => KarmashalaAboutDialog.show(_context);

  Future<void> clearAndReimport() async {
    final context = _context;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _ClearAndReimportDialog(),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await _ref
          .read(projectsControllerProvider.notifier)
          .clearAndReimportFromCli();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${summary.projects} projects and '
            '${summary.sessions} sessions.',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not rebuild workspace: $error')),
      );
    }
  }
}

class _ClearAndReimportDialog extends StatelessWidget {
  const _ClearAndReimportDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const DesktopDialogTitle(
      icon: AppIcons.arrowsClockwise,
      title: 'Rebuild workspace from CLI sessions?',
      subtitle: 'All current project entries will be replaced.',
    ),
    content: const BoundedDialogContent(
      width: DialogWidth.narrow,
      child: Text(
        'This clears projects and sessions from Karmashala, then scans '
        'Claude Code and Codex stores and imports everything it finds. '
        'Repository files and CLI sessions are not deleted.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      DestructiveButton(
        icon: const Icon(AppIcons.arrowsClockwise),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Clear and re-import'),
      ),
    ],
  );
}

/// **The window's menus behind one glyph** (UI overhaul board A2): the title
/// bar carries the logo and the quick panel, not three menu titles, so
/// Workspace, View and Tools are submenus of this one button — drawn like
/// every other menu in the app (see `shell_menu_items.dart`).
///
/// [icon] is `≡` in the title bar; the compact bar passes another glyph,
/// because its areas button already wears `≡` beside it.
class ShellMenuButton extends ConsumerWidget {
  const ShellMenuButton({
    this.icon = AppIcons.list,
    this.extent = Chrome.control,
    super.key,
  });

  final IconData icon;

  /// The square the glyph sits in: [Chrome.control] in the title bar, the
  /// compact bar's larger button there.
  final double extent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Bound to this button, which outlives the menu: an item's own context is
    // gone by the time its verb runs.
    final actions = ShellMenuActions(context, ref);
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: shellMenuPanelStyle(context),
      menuChildren: [
        WorkspaceMenu(actions),
        ViewMenu(actions),
        ToolsMenu(actions),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Menu',
        child: Semantics(
          button: true,
          expanded: controller.isOpen,
          label: 'Menu',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: SizedBox(
              width: extent,
              height: extent,
              child: Icon(
                icon,
                size: Chrome.icon,
                color: controller.isOpen
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// New project and session, go to, the CLI-store scans, and quit.
class WorkspaceMenu extends StatelessWidget {
  const WorkspaceMenu(this.actions, {super.key});

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context) => ShellSubmenu(
    label: 'Workspace',
    icon: AppIcons.folders,
    menuChildren: [
      ShellMenuItem(
        label: 'New session',
        icon: AppIcons.chatCircleDots,
        shortcut: shellCommandLabel('session.new'),
        onPressed: actions.newSession,
      ),
      ShellMenuItem(
        label: 'New project',
        icon: AppIcons.folderPlus,
        shortcut: shellCommandLabel('project.new'),
        onPressed: actions.newProject,
      ),
      const ShellMenuDivider(),
      ShellMenuItem(
        label: 'Go to…',
        icon: AppIcons.magnifyingGlass,
        shortcut: shellCommandLabel('quickOpen.show'),
        onPressed: actions.goTo,
      ),
      const ShellMenuDivider(),
      const ShellMenuHeader('CLI sessions'),
      ShellMenuItem(
        label: 'Detect CLI sessions',
        // `globe` is the Browser surface; scanning the CLI stores for sessions
        // is a search, not the web.
        icon: AppIcons.listMagnifyingGlass,
        // No chord: this is the scan you run a handful of times in a
        // workspace's life, and every chord left is one a shell can use.
        onPressed: actions.detectCliSessions,
      ),
      ShellMenuItem(
        label: 'Clear projects and re-import',
        icon: AppIcons.arrowsClockwise,
        // Unbound on purpose: rare *and* half destructive is the shape of
        // thing that should cost a deliberate trip through a menu.
        onPressed: actions.clearAndReimport,
      ),
      const ShellMenuDivider(),
      ShellMenuItem(
        label: 'Quit',
        icon: AppIcons.power,
        // ⌘Q on macOS only, where `MainFlutterWindow` catches it natively;
        // off a Mac it would be Ctrl+Q, which is XON, so nothing is shown.
        shortcut: commandKeyIsMeta ? '⌘Q' : null,
        onPressed: actions.quit,
      ),
    ],
  );
}

/// One row of the View menu. Both menu bars draw the same list — the window's
/// own ([ViewMenu]) and the macOS one (`NativeShellMenus`) — from
/// [viewMenuSections], so the two cannot drift.
sealed class ViewMenuEntry {
  const ViewMenuEntry();
}

class ViewMenuCommand extends ViewMenuEntry {
  const ViewMenuCommand({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.command,
    this.checked,
    this.nativeLabel,
  });

  final String label;
  final IconData icon;

  /// Null while there is nothing for it to act on.
  final VoidCallback? onPressed;

  /// The shell command whose chord the row names — read from the keymap, so a
  /// rebound key is the one shown.
  final String? command;

  /// A toggle's state, drawn as a check in the window's menu.
  final bool? checked;

  /// What the macOS menu bar says instead: it draws no check mark, so a toggle
  /// there names what it will do.
  final String? nativeLabel;
}

class ViewMenuSubmenu extends ViewMenuEntry {
  const ViewMenuSubmenu({
    required this.label,
    required this.icon,
    required this.entries,
  });

  final String label;
  final IconData icon;
  final List<ViewMenuEntry> entries;
}

/// **The View menu**, as groups between dividers: what the window shows.
///
/// One row per control. The strip's areas are not here — the strip is their
/// one place and its tooltips name Ctrl 1…5 — and neither is which tools More
/// lists, a preference that lives in Settings › Appearance › Sidebar & context
/// panel. The context panel is listed the way it is drawn: its toggle, then
/// its tabs in [ContextTab] order, History and More as submenus.
List<List<ViewMenuEntry>> viewMenuSections(
  WidgetRef ref,
  ShellMenuActions actions,
) {
  final sidebar = ref.watch(
    shellControllerProvider.select((s) => s.explorerPaneVisible),
  );
  final zen = ref.watch(terminalMaximizedProvider);
  final hasRoom = ref.watch(sidePanelRoomProvider);
  final panel = ref.watch(
    visibleSidePanelProvider.select((panel) => panel != null),
  );
  final hasTerminal = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
  );
  final more = [
    for (final surface in SidePanelSurface.offered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    ))
      if (ContextTab.of(surface) == ContextTab.more) surface,
  ];
  VoidCallback? withRoom(VoidCallback verb) => hasRoom ? verb : null;
  VoidCallback? withTerminal(VoidCallback verb) => hasTerminal ? verb : null;

  return [
    [
      ViewMenuCommand(
        label: 'Sidebar',
        nativeLabel: sidebar ? 'Hide sidebar' : 'Show sidebar',
        icon: AppIcons.treeStructure,
        checked: sidebar,
        // The chord that works everywhere — Ctrl+Shift+B, not the Ctrl+B that
        // belongs to tmux inside a pane (the skip-shell chord wins the label).
        command: 'view.toggleExplorer',
        onPressed: actions.toggleSidebar,
      ),
      ViewMenuCommand(
        label: 'Zen',
        nativeLabel: zen ? 'Leave Zen' : 'Enter Zen',
        icon: AppIcons.arrowsOutSimple,
        checked: zen,
        // Zen's own chord (spec §5): the older Ctrl+\ still works, but a shell
        // reads it as SIGQUIT.
        command: 'view.toggleFocusMode',
        onPressed: actions.toggleFocusMode,
      ),
    ],
    [
      ViewMenuCommand(
        label: hasRoom
            ? 'Context panel'
            : 'Context panel  ·  $kSidePanelNoRoom',
        nativeLabel: hasRoom
            ? (panel ? 'Hide context panel' : 'Show context panel')
            : null,
        icon: AppIcons.sidebarSimple,
        checked: panel,
        // Ctrl+Alt+B. The macOS bar used to draw ⌘3 here, which is the third
        // strip area, Terminals.
        command: 'view.toggleSidePanel',
        onPressed: withRoom(actions.toggleSidePanel),
      ),
      for (final tab in ContextTab.values)
        if (tab.surfaces.length == 1)
          ViewMenuCommand(
            label: tab.label,
            icon: SidePanel.tabIcon(tab),
            onPressed: withRoom(() => actions.showContextTab(tab)),
          )
        else
          // History's records, and every tool More can show — hidden from its
          // menu or not: taking one out of More is not switching it off.
          ViewMenuSubmenu(
            label: tab.label,
            icon: SidePanel.tabIcon(tab),
            entries: [
              for (final surface in tab == ContextTab.more
                  ? more
                  : tab.surfaces)
                ViewMenuCommand(
                  label: surface.label,
                  icon: SidePanel.iconFor(surface),
                  onPressed: withRoom(() => actions.showSurface(surface)),
                ),
            ],
          ),
    ],
    [
      // The focused terminal's own verbs. They left the title bar (spec §4:
      // find, usage and nothing else); each keeps its chord, and here its name.
      ViewMenuSubmenu(
        label: 'Terminal',
        icon: AppIcons.terminal,
        entries: [
          ViewMenuCommand(
            label: 'Find in scrollback',
            icon: AppIcons.magnifyingGlass,
            command: 'terminal.find',
            onPressed: withTerminal(actions.findInScrollback),
          ),
          ViewMenuCommand(
            label: 'Command snippets',
            icon: AppIcons.bookBookmark,
            command: 'quickOpen.snippets',
            onPressed: withTerminal(actions.commandSnippets),
          ),
          ViewMenuCommand(
            label: 'Commands run here…',
            icon: AppIcons.clockCounterClockwise,
            onPressed: withTerminal(actions.commandsRun),
          ),
        ],
      ),
    ],
  ];
}

/// The View menu in the window's own menu bar.
class ViewMenu extends ConsumerWidget {
  const ViewMenu(this.actions, {super.key});

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ShellSubmenu(
    label: 'View',
    icon: AppIcons.eye,
    menuChildren: [
      for (final (index, section) in viewMenuSections(
        ref,
        actions,
      ).indexed) ...[
        if (index > 0) const ShellMenuDivider(),
        for (final entry in section) _viewMenuRow(entry),
      ],
    ],
  );
}

Widget _viewMenuRow(ViewMenuEntry entry) => switch (entry) {
  ViewMenuCommand() => ShellMenuItem(
    label: entry.label,
    icon: entry.icon,
    checked: entry.checked,
    shortcut: entry.command == null ? null : shellCommandLabel(entry.command!),
    onPressed: entry.onPressed,
  ),
  ViewMenuSubmenu() => ShellSubmenu(
    label: entry.label,
    icon: entry.icon,
    menuChildren: [for (final child in entry.entries) _viewMenuRow(child)],
  ),
};

/// Settings and About.
class ToolsMenu extends StatelessWidget {
  const ToolsMenu(this.actions, {super.key});

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context) => ShellSubmenu(
    label: 'Tools',
    icon: AppIcons.squaresFour,
    menuChildren: [
      ShellMenuItem(
        label: 'Settings',
        icon: AppIcons.gearSix,
        // `Ctrl+,` / `⌘,` is the settings chord on every platform, and unlike
        // most Ctrl keys it is not one a shell claims.
        shortcut: shellCommandLabel('settings.open'),
        onPressed: actions.openSettings,
      ),
      const ShellMenuDivider(),
      ShellMenuItem(
        label: 'About Karmashala',
        icon: AppIcons.info,
        // No chord: a dialog you open once, to copy a build line into a bug
        // report.
        onPressed: actions.about,
      ),
    ],
  );
}
