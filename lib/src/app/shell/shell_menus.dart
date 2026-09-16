import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'karmashala_about_dialog.dart';
import 'quick_open/quick_open.dart';
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

  void toggleExplorer() =>
      _ref.read(shellControllerProvider.notifier).toggleExplorerPane();

  void toggleSidePanel() => _ref.read(sidePanelProvider.notifier).toggle();

  void showSurface(SidePanelSurface surface) =>
      _ref.read(sidePanelProvider.notifier).select(surface);

  void toggleFocusMode() =>
      _ref.read(terminalMaximizedProvider.notifier).toggle();

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

/// The window's three menus in a row.
class ShellMenuBar extends ConsumerWidget {
  const ShellMenuBar({super.key});

  /// The menu titles sit at the tab chips' size, weight and colour: they are
  /// chrome, not a heading over it, so full contrast only under the pointer.
  static ButtonStyle titleStyle(ColorScheme scheme) => ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)
          ? scheme.onSurface
          : scheme.onSurfaceVariant,
    ),
    minimumSize: const WidgetStatePropertyAll(Size(0, Chrome.control)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: Insets.sm),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ShellMenuActions(context, ref);
    final style = titleStyle(Theme.of(context).colorScheme);
    return MenuBar(
      children: [
        WorkspaceMenu(actions, style: style),
        ViewMenu(actions, style: style),
        ToolsMenu(actions, style: style),
      ],
    );
  }
}

/// The same three menus behind one glyph, for a row too narrow for their
/// titles.
class ShellOverflowMenu extends ConsumerWidget {
  const ShellOverflowMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ShellMenuActions(context, ref);
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      menuChildren: [
        WorkspaceMenu(actions),
        ViewMenu(actions),
        ToolsMenu(actions),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Menu',
        constraints: const BoxConstraints.tightFor(
          width: Chrome.control,
          height: Chrome.control,
        ),
        padding: EdgeInsets.zero,
        iconSize: Chrome.icon,
        color: scheme.onSurfaceVariant,
        icon: const Icon(AppIcons.dotsThreeVertical),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// New project and session, go to, the CLI-store scans, and quit.
class WorkspaceMenu extends StatelessWidget {
  const WorkspaceMenu(this.actions, {this.style, super.key});

  final ShellMenuActions actions;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) => SubmenuButton(
    style: style,
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.folderPlus),
        shortcut: commandActivator(LogicalKeyboardKey.keyN, shift: true),
        onPressed: actions.newProject,
        child: const Text('New project'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.chatCircleDots),
        shortcut: commandActivator(LogicalKeyboardKey.keyN),
        onPressed: actions.newSession,
        child: const Text('New session'),
      ),
      const Divider(height: 1),
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.magnifyingGlass),
        shortcut: commandActivator(LogicalKeyboardKey.keyK),
        onPressed: actions.goTo,
        child: const Text('Go to…'),
      ),
      const Divider(height: 1),
      MenuItemButton(
        // `globe` is the Browser surface; scanning the CLI stores for sessions
        // is a search, not the web.
        leadingIcon: const Icon(AppIcons.listMagnifyingGlass),
        // No chord: this is the scan you run a handful of times in a
        // workspace's life, and every chord left is one a shell can use.
        onPressed: actions.detectCliSessions,
        child: const Text('Detect CLI sessions'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.arrowsClockwise),
        // Unbound on purpose: rare *and* half destructive is the shape of
        // thing that should cost a deliberate trip through a menu.
        onPressed: actions.clearAndReimport,
        child: const Text('Clear projects and re-import'),
      ),
      const Divider(height: 1),
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.power),
        // ⌘Q on macOS only, written out rather than reached through
        // `commandActivator`: off a Mac that becomes Ctrl+Q, which is XON.
        shortcut: commandKeyIsMeta
            ? const SingleActivator(LogicalKeyboardKey.keyQ, meta: true)
            : null,
        onPressed: actions.quit,
        child: const Text('Quit'),
      ),
    ],
    child: const Text('Workspace'),
  );
}

/// What the window shows: the Explorer, the side panel and its surfaces, and
/// focus mode.
class ViewMenu extends ConsumerWidget {
  const ViewMenu(this.actions, {this.style, super.key});

  final ShellMenuActions actions;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = SidePanelSurface.offered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    );
    return SubmenuButton(
      style: style,
      menuChildren: [
        _ExplorerCheckItem(actions),
        _SidePanelCheckItem(actions),
        const Divider(height: 1),
        // The surfaces the panel can show, so every tool is reachable from the
        // menu bar and not only from a glyph on the rail.
        for (final surface in surfaces)
          MenuItemButton(
            leadingIcon: Icon(SidePanel.iconFor(surface)),
            // The inbox already had this chord and the menu never said so. The
            // others stay bare: more chords is more keys taken.
            shortcut: surface == SidePanelSurface.inbox
                ? commandActivator(LogicalKeyboardKey.keyA, shift: true)
                : null,
            onPressed: () => actions.showSurface(surface),
            child: Text(surface.label),
          ),
        const Divider(height: 1),
        _FocusModeCheckItem(actions),
      ],
      child: const Text('View'),
    );
  }
}

class _ExplorerCheckItem extends ConsumerWidget {
  const _ExplorerCheckItem(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CheckboxMenuButton(
    value: ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    ),
    // Ctrl+Shift+B, not Ctrl+B: a menu should teach the chord that works
    // everywhere, and Ctrl+B belongs to tmux inside a pane.
    shortcut: commandActivator(LogicalKeyboardKey.keyB, shift: true),
    onChanged: (_) => actions.toggleExplorer(),
    child: const Text('Explorer'),
  );
}

class _SidePanelCheckItem extends ConsumerWidget {
  const _SidePanelCheckItem(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CheckboxMenuButton(
    value: ref.watch(sidePanelProvider.select((panel) => panel != null)),
    shortcut: commandActivator(LogicalKeyboardKey.digit3),
    onChanged: (_) => actions.toggleSidePanel(),
    child: const Text('Side panel'),
  );
}

class _FocusModeCheckItem extends ConsumerWidget {
  const _FocusModeCheckItem(this.actions);

  final ShellMenuActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CheckboxMenuButton(
    value: ref.watch(terminalMaximizedProvider),
    shortcut: commandActivator(LogicalKeyboardKey.backslash),
    onChanged: (_) => actions.toggleFocusMode(),
    child: const Text('Focus mode'),
  );
}

/// Settings and About.
class ToolsMenu extends StatelessWidget {
  const ToolsMenu(this.actions, {this.style, super.key});

  final ShellMenuActions actions;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) => SubmenuButton(
    style: style,
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.gearSix),
        // `Ctrl+,` / `⌘,` is the settings chord on every platform, and unlike
        // most Ctrl keys it is not one a shell claims.
        shortcut: commandActivator(LogicalKeyboardKey.comma),
        onPressed: actions.openSettings,
        child: const Text('Settings'),
      ),
      const Divider(height: 1),
      MenuItemButton(
        leadingIcon: const Icon(AppIcons.info),
        // No chord: a dialog you open once, to copy a build line into a bug
        // report.
        onPressed: actions.about,
        child: const Text('About Karmashala'),
      ),
    ],
    child: const Text('Tools'),
  );
}
