import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../widgets/desktop_dialog.dart';
import 'app_mode.dart';
import 'resize_handle.dart';

import '../../features/detail/presentation/detail_panel.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/settings/application/settings_controller.dart';
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
  Size get preferredSize => const Size.fromHeight(40);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalVisible = ref.watch(terminalVisibleProvider);
    // No app icon/name here — the OS title bar already shows those. Lead with the
    // menu bar so the chrome reads like a native desktop menu bar.
    return AppBar(
      titleSpacing: 8,
      title: const Align(
        alignment: Alignment.centerLeft,
        child: _DesktopMenuBar(),
      ),
      actions: [
        IconButton(
          tooltip: 'Mini launcher',
          icon: const Icon(AppIcons.pictureInpicture),
          onPressed: () => ref.read(appModeProvider.notifier).enterMini(),
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(AppIcons.gearSix),
          onPressed: () => SettingsScreen.show(context),
        ),
        IconButton(
          tooltip: 'Toggle terminal (Ctrl+`)',
          isSelected: terminalVisible,
          icon: const Icon(AppIcons.terminal),
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
          icon: AppIcons.arrowsClockwise,
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
            icon: const Icon(AppIcons.arrowsClockwise, size: 16),
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
              leadingIcon: const Icon(AppIcons.folderPlus),
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
                shift: true,
              ),
              onPressed: () => NewProjectDialog.show(context),
              child: const Text('New project'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.chatCircleDots),
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
              leadingIcon: const Icon(AppIcons.globe),
              onPressed: () => _showDetected(context, ref),
              child: const Text('Detect CLI sessions'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.arrowsClockwise),
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
              leadingIcon: const Icon(AppIcons.gearSix),
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
class _SplitLayout extends ConsumerStatefulWidget {
  const _SplitLayout({required this.shell});
  final ShellState shell;

  @override
  ConsumerState<_SplitLayout> createState() => _SplitLayoutState();
}

class _SplitLayoutState extends ConsumerState<_SplitLayout> {
  static const _min = 220.0;
  static const _max = 620.0;
  double? _width;

  @override
  Widget build(BuildContext context) {
    _width ??= ref.read(
      settingsControllerProvider.select((s) => s.explorerPaneWidth),
    );
    final width = _width!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.shell.explorerPaneVisible) ...[
          SizedBox(
            width: width.clamp(_min, _max),
            child: const ExplorerPanel(),
          ),
          ResizeHandle(
            onDelta: (dx) =>
                setState(() => _width = (width + dx).clamp(_min, _max)),
            onEnd: () => ref
                .read(settingsControllerProvider.notifier)
                .setExplorerPaneWidth(_width!.clamp(_min, _max)),
          ),
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
              icon: Icon(AppIcons.treeStructure),
              label: Text('Explorer'),
            ),
            ButtonSegment(
              value: ShellPane.detail,
              icon: Icon(AppIcons.article),
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
