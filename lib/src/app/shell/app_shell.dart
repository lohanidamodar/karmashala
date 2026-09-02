import 'dart:async';

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
import '../../features/notes/application/notes_providers.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/system/system_integration_service.dart';
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
/// The terminal is not a dock any more. Karmashala is terminal-primary (see
/// the design note), so the
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
        // The bar's height follows the text scale (menus must not clip at
        // 125%+), and `preferredSize` cannot read a context — so the shell
        // measures and passes it down.
        appBar: ShellTitleBar(height: Chrome.titleBarOf(context)),
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

/// The window's one chrome row: the menus, the command field and the toggles
/// for the two panes that can be hidden.
///
/// It used to be a Material `AppBar` 32px tall, against the 30px of every other
/// chrome row in the window, in the same colour and with no rule under it — so
/// the top-left of the window read as one 62px slab with `Workspace View Tools`
/// sitting over `EXPLORER`. Six controls were parked at the right (a chat
/// drawer, a mini launcher, settings, a divider and two toggles), which is
/// where things go when nowhere else has claimed them.
///
/// Now it *is* the tab strip's row: the same height, the same
/// `surfaceContainerLow`, the same hairline underneath, and the menus at the
/// tab chips' size and weight instead of a step larger and brighter. Each pane
/// toggle moved to the side of the window it controls, and it is drawn like a
/// rail button, because that is the other place in the chrome where a glyph
/// means "show me this".
class ShellTitleBar extends ConsumerWidget implements PreferredSizeWidget {
  const ShellTitleBar({this.height = Chrome.titleBar, super.key});

  /// The row's height — [Chrome.titleBar] scaled by the text size at the use
  /// site (see [Chrome.titleBarOf]).
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final panelOpen = ref.watch(sidePanelProvider) != null;
    final explorerVisible = ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    );
    // No app icon or name: the OS title bar already carries those.
    return Material(
      color: scheme.surfaceContainerLow,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            _ChromeToggle(
              icon: AppIcons.treeStructure,
              label: 'Show or hide the Explorer',
              chord: shellChordLabel<ToggleExplorerPaneIntent>(),
              note: 'Ctrl+B does it too, outside a terminal pane',
              selected: explorerVisible,
              onPressed: () => ref
                  .read(shellControllerProvider.notifier)
                  .toggleExplorerPane(),
            ),
            const SizedBox(width: Insets.xs),
            const _DesktopMenuBar(),
            const SizedBox(width: Insets.sm),
            // Expanded, not Flexible-then-Spacer: the field takes its own
            // width and the rest of the row is empty space the toggles are
            // pushed to the far edge by.
            const Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: QuickOpenButton(),
              ),
            ),
            _ChromeToggle(
              icon: AppIcons.sidebarSimple,
              label: 'Show or hide the side panel',
              chord: shellChordLabel<ToggleSidePanelIntent>(),
              selected: panelOpen,
              onPressed: () => ref.read(sidePanelProvider.notifier).toggle(),
            ),
            _ChromeToggle(
              icon: AppIcons.gearSix,
              label: 'Settings',
              onPressed: () => SettingsScreen.show(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// A title-bar glyph, drawn like a rail button so the two places in the chrome
/// where an icon means "show me this" look like one control.
class _ChromeToggle extends StatelessWidget {
  const _ChromeToggle({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.chord,
    this.note,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? chord;
  final String? note;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: [
        [label, ?chord].join('  ·  '),
        ?note,
      ].join('\n'),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onPressed,
          child: Container(
            width: 26,
            height: 24,
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Icon(
              icon,
              size: Chrome.icon,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopMenuBar extends ConsumerWidget {
  const _DesktopMenuBar();

  /// The menu titles sit at the tab chips' size, weight and colour, and only
  /// come up to full contrast under the pointer. They are chrome, not a
  /// heading over the chrome: at `onSurface` they were the brightest thing in
  /// the window's top-left corner, above the pane header they belong beside.
  static ButtonStyle _titleStyle(ColorScheme scheme) => ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)
          ? scheme.onSurface
          : scheme.onSurfaceVariant,
    ),
    minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: Insets.sm),
    ),
  );

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
    final style = _titleStyle(Theme.of(context).colorScheme);
    return MenuBar(
      children: [
        SubmenuButton(
          style: style,
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
            const Divider(height: 1),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.power),
              // The real exit, whatever close-to-tray does to the window: the
              // tray's own Quit, so shutdown runs in order either way.
              onPressed: () {
                final system = ref.read(systemIntegrationProvider);
                if (system != null) unawaited(system.quit());
              },
              child: const Text('Quit'),
            ),
          ],
          child: const Text('Workspace'),
        ),
        SubmenuButton(
          style: style,
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
            for (final surface in SidePanelSurface.offered(
              debugMode: ref.watch(
                settingsControllerProvider.select((s) => s.debugMode),
              ),
              notesEnabled: ref.watch(notesEnabledProvider),
            ))
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
          style: style,
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
