import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../widgets/desktop_dialog.dart';

import '../../features/detail/presentation/detail_panel.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';

/// The adaptive two-pane desktop shell: Explorer | Detail.
///
/// Layout adapts to the available width:
/// * **Wide/Medium** (≥ 760): Explorer tree beside the Detail view, with the
///   Explorer collapsible via `Ctrl+B`.
/// * **Narrow** (< 760): a single pane (the focused one) with a bottom selector.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const double _mediumBreakpoint = 760;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellControllerProvider);
    final terminalVisible = ref.watch(terminalVisibleProvider);
    return ShellShortcuts(
      child: Scaffold(
        appBar: const _ShellAppBar(),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= _mediumBreakpoint) {
                        return _SplitLayout(shell: shell);
                      }
                      return _NarrowLayout(shell: shell);
                    },
                  ),
                ),
              ),
              if (terminalVisible)
                const SizedBox(height: 280, child: TerminalPanel()),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _ShellAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(46);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalVisible = ref.watch(terminalVisibleProvider);
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 22,
            color: Theme.of(context).colorScheme.tertiary,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chitragupta',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'THE AGENT LEDGER',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          if (MediaQuery.sizeOf(context).width >= 900) ...[
            const SizedBox(width: 18),
            const _DesktopMenuBar(),
          ],
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => SettingsScreen.show(context),
        ),
        IconButton(
          tooltip: 'Toggle terminal (Ctrl+`)',
          isSelected: terminalVisible,
          icon: const Icon(Icons.terminal),
          onPressed: () => ref.read(terminalVisibleProvider.notifier).toggle(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _DesktopMenuBar extends ConsumerWidget {
  const _DesktopMenuBar();

  void _showDetected(BuildContext context, WidgetRef ref) {
    ref.read(detectedProjectsControllerProvider.notifier).detect();
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 680),
          child: const DetectedProjectsView(),
        ),
      ),
    );
  }

  Future<void> _clearAndReimport(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: Icons.sync,
          title: 'Rebuild workspace from CLI sessions?',
          subtitle: 'All current project entries will be replaced.',
        ),
        content: const SizedBox(
          width: 440,
          child: Text(
            'This clears projects and sessions from Chitragupta, then scans '
            'Claude Code and Codex stores and imports everything it finds. '
            'Repository files and CLI sessions are not deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.sync, size: 16),
            onPressed: () => Navigator.of(context).pop(true),
            label: const Text('Clear and re-import'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await ref
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedRepo = ref.watch(selectedRepositoryIdProvider);
    final shell = ref.watch(shellControllerProvider);
    final terminalVisible = ref.watch(terminalVisibleProvider);
    final sidebarVisible = ref.watch(detailSidebarVisibleProvider);
    return MenuBar(
      children: [
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.create_new_folder_outlined),
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
                shift: true,
              ),
              onPressed: () => NewProjectDialog.show(context),
              child: const Text('New project'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.add_comment_outlined),
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
              ),
              onPressed: selectedRepo == null
                  ? null
                  : () => NewSessionDialog.show(context),
              child: const Text('New session'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              leadingIcon: const Icon(Icons.travel_explore_outlined),
              onPressed: () => _showDetected(context, ref),
              child: const Text('Detect CLI sessions'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.sync),
              onPressed: () => _clearAndReimport(context, ref),
              child: const Text('Clear projects and re-import'),
            ),
          ],
          child: const Text('Workspace'),
        ),
        SubmenuButton(
          menuChildren: [
            CheckboxMenuButton(
              value: shell.explorerPaneVisible,
              onChanged: (_) => ref
                  .read(shellControllerProvider.notifier)
                  .toggleExplorerPane(),
              child: const Text('Explorer'),
            ),
            CheckboxMenuButton(
              value: sidebarVisible,
              onChanged: (_) =>
                  ref.read(detailSidebarVisibleProvider.notifier).toggle(),
              child: const Text('Detail sidebar'),
            ),
            CheckboxMenuButton(
              value: terminalVisible,
              onChanged: (_) =>
                  ref.read(terminalVisibleProvider.notifier).toggle(),
              child: const Text('Terminal'),
            ),
          ],
          child: const Text('View'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.settings_outlined),
              onPressed: () => SettingsScreen.show(context),
              child: const Text('Settings'),
            ),
          ],
          child: const Text('Tools'),
        ),
      ],
    );
  }
}

/// Split: the Explorer tree beside the Detail view, Explorer collapsible.
class _SplitLayout extends StatelessWidget {
  const _SplitLayout({required this.shell});
  final ShellState shell;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shell.explorerPaneVisible) ...[
          const SizedBox(width: 304, child: ExplorerPanel()),
          const SizedBox(width: 4),
        ],
        const Expanded(child: DetailPanel()),
      ],
    );
  }
}

/// Narrow: only the focused pane, with a selector to switch panes.
class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout({required this.shell});
  final ShellState shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final Widget active = switch (shell.focusedPane) {
      ShellPane.explorer => const ExplorerPanel(),
      ShellPane.detail => const DetailPanel(),
    };
    return Column(
      children: [
        Expanded(child: active),
        const SizedBox(height: 8),
        SegmentedButton<ShellPane>(
          segments: const [
            ButtonSegment(
              value: ShellPane.explorer,
              icon: Icon(Icons.account_tree_outlined),
              label: Text('Explorer'),
            ),
            ButtonSegment(
              value: ShellPane.detail,
              icon: Icon(Icons.article_outlined),
              label: Text('Detail'),
            ),
          ],
          selected: {shell.focusedPane},
          onSelectionChanged: (selection) =>
              controller.focusPane(selection.first),
        ),
      ],
    );
  }
}
