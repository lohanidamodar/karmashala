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
import 'shell_area.dart';
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

  void toggleExplorer() =>
      _ref.read(shellControllerProvider.notifier).toggleExplorerPane();

  void toggleSidePanel() => _ref.read(sidePanelProvider.notifier).toggle();

  void showSurface(SidePanelSurface surface) =>
      _ref.read(sidePanelProvider.notifier).select(surface);

  void setSurfaceHidden(SidePanelSurface surface, {required bool hidden}) =>
      _ref
          .read(settingsControllerProvider.notifier)
          .setSidePanelSurfaceHidden(surface.name, hidden: hidden);

  void showAllSurfaces() =>
      _ref.read(settingsControllerProvider.notifier).showAllSidePanelSurfaces();

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

/// What the window shows: the sidebar, the context panel and its surfaces, the
/// terminal's verbs, and Zen.
class ViewMenu extends ConsumerWidget {
  const ViewMenu(this.actions, {super.key});

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRoom = ref.watch(sidePanelRoomProvider);
    final surfaces = SidePanelSurface.offered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    );
    return ShellSubmenu(
      label: 'View',
      icon: AppIcons.eye,
      menuChildren: [
        _ExplorerCheckItem(actions),
        _SidePanelCheckItem(actions),
        _FocusModeCheckItem(actions),
        const ShellMenuDivider(),
        // The Inbox is an area of the activity strip; the menu names the chord
        // that reaches it, which it has had since it was bound.
        ShellMenuItem(
          label: 'Inbox',
          icon: AppIcons.tray,
          shortcut: shellCommandLabel('attention.toggleInbox'),
          onPressed: () => showShellArea(ref, ShellArea.inbox),
        ),
        // The terminal's verbs left the title bar (spec §4: find, usage and
        // nothing else); each keeps its chord, and here its name.
        _TerminalSubmenu(actions),
        const ShellMenuDivider(),
        // The surfaces the context panel can show, so every tool is reachable
        // from the menu. They stay bare: more chords is more keys taken.
        const ShellMenuHeader('Context panel'),
        for (final surface in surfaces)
          ShellMenuItem(
            label: surface.label,
            icon: SidePanel.iconFor(surface),
            onPressed: hasRoom ? () => actions.showSurface(surface) : null,
          ),
        _SidePanelItemsSubmenu(actions),
      ],
    );
  }
}

class _ExplorerCheckItem extends ConsumerWidget {
  const _ExplorerCheckItem(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ShellMenuItem(
    label: 'Sidebar',
    icon: AppIcons.treeStructure,
    checked: ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    ),
    // The chord that works everywhere — Ctrl+Shift+B, not the Ctrl+B that
    // belongs to tmux inside a pane (the skip-shell chord wins the label).
    shortcut: shellCommandLabel('view.toggleExplorer'),
    onPressed: actions.toggleExplorer,
  );
}

class _SidePanelCheckItem extends ConsumerWidget {
  const _SidePanelCheckItem(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRoom = ref.watch(sidePanelRoomProvider);
    return ShellMenuItem(
      label: hasRoom ? 'Context panel' : 'Context panel  ·  $kSidePanelNoRoom',
      icon: AppIcons.sidebarSimple,
      checked: ref.watch(
        visibleSidePanelProvider.select((panel) => panel != null),
      ),
      // The chord the title bar's side-panel toggle names. The menu used to
      // draw Ctrl+3, which is the third activity-strip area, not this.
      shortcut: shellCommandLabel('view.toggleSidePanel'),
      onPressed: hasRoom ? actions.toggleSidePanel : null,
    );
  }
}

/// Which tools the context panel's More tab lists — the same list as Settings
/// › Appearance › Sidebar & context panel. Hiding changes a preference, not
/// the panel, so it needs no room.
class _SidePanelItemsSubmenu extends ConsumerWidget {
  const _SidePanelItemsSubmenu(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hiddenSidePanelSurfacesProvider);
    final surfaces = SidePanelSurface.offered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    );
    return ShellSubmenu(
      label: 'Tools in More',
      icon: AppIcons.dotsThree,
      menuChildren: [
        for (final surface in surfaces)
          ShellMenuCheckItem(
            label: surface.label,
            icon: SidePanel.iconFor(surface),
            checked: !hidden.contains(surface),
            onChanged: (visible) =>
                actions.setSurfaceHidden(surface, hidden: !visible),
          ),
        const ShellMenuDivider(),
        ShellMenuItem(
          label: 'Show all',
          icon: AppIcons.arrowCounterClockwise,
          onPressed: hidden.isEmpty ? null : actions.showAllSurfaces,
        ),
      ],
    );
  }
}

class _FocusModeCheckItem extends ConsumerWidget {
  const _FocusModeCheckItem(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ShellMenuItem(
    label: 'Zen',
    icon: AppIcons.arrowsOutSimple,
    checked: ref.watch(terminalMaximizedProvider),
    // Zen's own chord (spec §5), as the title bar's toggle names it: the
    // older Ctrl+\ still works, but a shell reads it as SIGQUIT.
    shortcut: shellCommandLabel('view.toggleFocusMode'),
    onPressed: actions.toggleFocusMode,
  );
}

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

/// The focused terminal's own verbs: find in its scrollback, the snippets, and
/// the commands it has run. Takes the host's [actions]: its own context lives
/// in the menu, and is gone by the time a dialog needs it.
class _TerminalSubmenu extends ConsumerWidget {
  const _TerminalSubmenu(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTabs = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
    );
    return ShellSubmenu(
      label: 'Terminal',
      icon: AppIcons.terminal,
      menuChildren: [
        ShellMenuItem(
          label: 'Find in scrollback',
          icon: AppIcons.magnifyingGlass,
          shortcut: shellCommandLabel('terminal.find'),
          onPressed: hasTabs ? actions.findInScrollback : null,
        ),
        ShellMenuItem(
          label: 'Command snippets',
          icon: AppIcons.bookBookmark,
          shortcut: shellCommandLabel('quickOpen.snippets'),
          onPressed: hasTabs ? actions.commandSnippets : null,
        ),
        ShellMenuItem(
          label: 'Commands run here…',
          icon: AppIcons.clockCounterClockwise,
          onPressed: hasTabs ? actions.commandsRun : null,
        ),
      ],
    );
  }
}
