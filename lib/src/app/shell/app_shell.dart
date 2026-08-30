import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import '../widgets/desktop_dialog.dart';
import 'resize_handle.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';
import 'status_bar.dart';
import 'workbench.dart';

import '../../core/database/database_providers.dart';
import '../../features/environments/presentation/environment_health_dialog.dart';
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
import 'quick_open/quick_open.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';

/// Width classes for the desktop shell, in one place (see `CLAUDE.md` §6).
///
/// Branching on width rather than platform, and naming the classes here rather
/// than scattering `constraints.maxWidth > 760` through the panes, is what keeps
/// "responsive" a property of the shell instead of a per-widget afterthought.
enum ShellWidth {
  /// One pane at a time, chosen with a selector. The side panel's rail stays —
  /// it is 34px and it is the only way back to the tools.
  compact,

  /// Explorer beside the workbench. An open side panel eats into the workbench,
  /// which its own clamp keeps survivable.
  medium,

  /// Everything at its natural width.
  expanded;

  static ShellWidth of(double width) {
    if (width < 760) return ShellWidth.compact;
    if (width < 1180) return ShellWidth.medium;
    return ShellWidth.expanded;
  }

  bool get isCompact => this == ShellWidth.compact;
}

/// The desktop shell: Explorer · Workbench · side panel, over a status bar.
///
/// The terminal is not a dock any more. Chitragupta is terminal-primary (see
/// `docs/superpowers/specs/2026-08-30-session-daemon-direction.md`), so the
/// terminal and its tabs live in the middle of the window and the navigation
/// stays on the left — the shape Orca, cmux, Warp and Ghostty all converge on.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final database = ref.read(databaseProvider);
      if (database.readMetadata(MetadataKeys.environmentHealthOnboarding) !=
          'pending') {
        return;
      }
      database.writeMetadata(MetadataKeys.environmentHealthOnboarding, 'shown');
      EnvironmentHealthDialog.show(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellControllerProvider);
    // Focus mode: the workbench takes the window. The provider is the old
    // "maximize the dock" flag, which is the same intent now that the dock is
    // gone — everything but the work gets out of the way.
    final zen = ref.watch(terminalMaximizedProvider);
    // The global hotkey summons the window with quick open already up; the
    // service that registers it lives outside the tree, so it bumps a counter
    // and the shell — which has a Navigator above it — opens the dialog.
    ref.listen(quickOpenRequestProvider, (_, _) {
      if (mounted) QuickOpen.show(context);
    });
    return ShellShortcuts(
      child: Scaffold(
        appBar: const _ShellTitleBar(),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = ShellWidth.of(constraints.maxWidth);
              // At compact widths the Explorer and the workbench take turns
              // in the same column; the side panel keeps only its rail.
              final showExplorer = width.isCompact
                  ? shell.focusedPane == ShellPane.explorer
                  : shell.explorerPaneVisible;
              return Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!zen && showExplorer)
                          width.isCompact
                              ? const Expanded(child: ExplorerPanel())
                              : _ExplorerColumn(
                                  available: constraints.maxWidth,
                                ),
                        if (!width.isCompact || !showExplorer)
                          const Expanded(child: WorkbenchView()),
                        if (!zen) const SidePanel(),
                      ],
                    ),
                  ),
                  if (width.isCompact && !zen)
                    _CompactPaneSelector(shell: shell),
                  const ShellStatusBar(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// At compact widths there is only room for one pane, so a selector says which.
class _CompactPaneSelector extends ConsumerWidget {
  const _CompactPaneSelector({required this.shell});

  final ShellState shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: Chrome.tabStrip + Insets.sm,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SegmentedButton<ShellPane>(
        segments: const [
          ButtonSegment(
            value: ShellPane.explorer,
            icon: Icon(AppIcons.treeStructure, size: Chrome.iconSmall),
            label: Text('Explorer'),
          ),
          ButtonSegment(
            value: ShellPane.detail,
            icon: Icon(AppIcons.terminal, size: Chrome.iconSmall),
            label: Text('Workbench'),
          ),
        ],
        showSelectedIcon: false,
        selected: {shell.focusedPane},
        onSelectionChanged: (selection) =>
            controller.focusPane(selection.first),
      ),
    );
  }
}

/// The Explorer with a draggable right edge; its width is persisted.
class _ExplorerColumn extends ConsumerStatefulWidget {
  const _ExplorerColumn({required this.available});

  final double available;

  @override
  ConsumerState<_ExplorerColumn> createState() => _ExplorerColumnState();
}

class _ExplorerColumnState extends ConsumerState<_ExplorerColumn> {
  static const _min = 200.0;
  static const _max = 560.0;
  double? _width;

  @override
  Widget build(BuildContext context) {
    _width ??= ref.read(
      settingsControllerProvider.select((s) => s.explorerPaneWidth),
    );
    // A saved desktop width must not crush the workbench when the window is
    // later restored or resized smaller. Always reserve a useful work surface.
    final responsiveMax = (widget.available - 520).clamp(_min, _max);
    final width = _width!.clamp(_min, responsiveMax);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: width, child: const ExplorerPanel()),
        ResizeHandle(
          semanticLabel: 'Resize Explorer width',
          onDelta: (dx) =>
              setState(() => _width = (width + dx).clamp(_min, responsiveMax)),
          onEnd: () => ref
              .read(settingsControllerProvider.notifier)
              .setExplorerPaneWidth(_width!.clamp(_min, _max)),
        ),
      ],
    );
  }
}

class _ShellTitleBar extends ConsumerWidget implements PreferredSizeWidget {
  const _ShellTitleBar();

  @override
  Size get preferredSize => const Size.fromHeight(Chrome.titleBar);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = ref.watch(sidePanelProvider) != null;
    final explorerVisible = ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    );
    // No app icon/name here — the OS title bar already shows those. Lead with
    // the menu bar so the chrome reads like a native desktop menu bar.
    return AppBar(
      titleSpacing: Insets.xs,
      title: const Row(
        children: [
          _DesktopMenuBar(),
          SizedBox(width: Insets.sm),
          // Quick open had no mouse affordance at all (Loop 50 §8.1): no
          // button, no menu item, nothing to click. A search field beside the
          // menus is where every desktop app of this shape puts it, and it is
          // also the only place the chord can teach itself.
          Flexible(child: QuickOpenButton()),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(AppIcons.gearSix),
          onPressed: () => SettingsScreen.show(context),
        ),
        const VerticalDivider(indent: 7, endIndent: 7, width: Insets.sm),
        IconButton(
          tooltip:
              'Toggle Explorer  ·  '
              '${shellChordLabel<ToggleExplorerPaneIntent>()}'
              '  (Ctrl+B outside a terminal pane)',
          isSelected: explorerVisible,
          icon: const Icon(AppIcons.treeStructure),
          onPressed: () =>
              ref.read(shellControllerProvider.notifier).toggleExplorerPane(),
        ),
        IconButton(
          tooltip:
              'Toggle side panel  ·  ${shellChordLabel<ToggleSidePanelIntent>()}',
          isSelected: panelOpen,
          icon: const Icon(AppIcons.sidebarSimple),
          onPressed: () => ref.read(sidePanelProvider.notifier).toggle(),
        ),
        const SizedBox(width: Insets.xs),
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
    final panel = ref.watch(sidePanelProvider);
    final zen = ref.watch(terminalMaximizedProvider);
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
              leadingIcon: const Icon(AppIcons.magnifyingGlass),
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyK,
                control: true,
              ),
              onPressed: () => QuickOpen.show(context),
              child: const Text('Go to…'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              // `globe` is the Browser surface; scanning the CLI stores for
              // sessions is a search, not the web.
              leadingIcon: const Icon(AppIcons.listMagnifyingGlass),
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
              // Ctrl+Shift+B, not Ctrl+B: a menu should teach the chord that
              // works everywhere, and Ctrl+B belongs to tmux inside a pane.
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyB,
                control: true,
                shift: true,
              ),
              onChanged: (_) => ref
                  .read(shellControllerProvider.notifier)
                  .toggleExplorerPane(),
              child: const Text('Explorer'),
            ),
            CheckboxMenuButton(
              value: panel != null,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.digit3,
                control: true,
              ),
              onChanged: (_) => ref.read(sidePanelProvider.notifier).toggle(),
              child: const Text('Side panel'),
            ),
            const Divider(height: 1),
            // The surfaces the panel can show, so every tool is reachable from
            // the menu bar and not only from a glyph on the rail.
            for (final surface in SidePanelSurface.values)
              MenuItemButton(
                leadingIcon: Icon(SidePanel.iconFor(surface)),
                onPressed: () =>
                    ref.read(sidePanelProvider.notifier).select(surface),
                child: Text(surface.label),
              ),
            const Divider(height: 1),
            CheckboxMenuButton(
              value: zen,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.backslash,
                control: true,
              ),
              onChanged: (_) =>
                  ref.read(terminalMaximizedProvider.notifier).toggle(),
              child: const Text('Focus mode'),
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
