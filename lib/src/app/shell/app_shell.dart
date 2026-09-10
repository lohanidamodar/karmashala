import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import '../widgets/desktop_dialog.dart';
import 'karmashala_about_dialog.dart';
import 'resize_handle.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';
import 'status_bar.dart';
import 'workbench.dart';

import '../../core/database/database_providers.dart';
import '../../features/automations/application/automation_runner.dart';
import '../../features/automations/application/automation_scheduler.dart';
import '../../features/environments/presentation/environment_health_dialog.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../features/flutter_apps/application/flutter_gate_observer.dart';
import '../../features/git/application/worktree_setup_providers.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/notes/application/notes_providers.dart';
import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/system/system_integration_service.dart';
import '../../features/sessions/application/session_liveness_reconciler.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'quick_open/quick_open.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';

/// Width classes for the desktop shell, in one place (see `CLAUDE.md` §6).
/// Branching on width rather than platform is what keeps "responsive" a
/// property of the shell instead of a per-widget afterthought.
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
/// Terminal-primary, so the terminal is the middle of the window, not a dock.
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
    // Watched, not read: Riverpod 3 pauses a provider's own subscriptions while
    // nothing listens, so a reconciler nobody watches never hears a pane stop.
    ref.watch(sessionLivenessReconcilerProvider);
    // Same reason: a worktree setup command runs in its own pane, and only a
    // listening observer turns its exit code into a recorded verdict.
    ref.watch(worktreeSetupExitObserverProvider);
    // And again for the Flutter gates, which run in their own panes too.
    ref.watch(flutterGateObserverProvider);
    // And again, twice, for scheduled automations: an unwatched scheduler arms
    // no timer and an unwatched observer records no verdict, both silently.
    ref.watch(automationSchedulerProvider);
    ref.watch(automationRunObserverProvider);
    // Focus mode: the workbench takes the window.
    final zen = ref.watch(terminalMaximizedProvider);
    // The global hotkey summons the window with quick open up; the service that
    // registers it lives outside the tree, so it bumps a counter for the shell.
    ref.listen(quickOpenRequestProvider, (_, _) {
      if (mounted) QuickOpen.show(context);
    });
    return ShellShortcuts(
      child: Scaffold(
        // The bar's height follows the text scale (menus must not clip at
        // 125%+), and `preferredSize` cannot read a context.
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
/// for the two panes that can be hidden. Built as the tab strip's row — same
/// height, same surface, same hairline — because it is chrome, not a heading.
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
    final width = ShellWidth.of(MediaQuery.sizeOf(context).width);
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
            // width and the toggles are pushed to the far edge by the rest.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth < 64
                    // Below its own leading glyph there is nothing to draw. The
                    // field is a convenience — `Ctrl+K` is the same command.
                    ? const SizedBox.shrink()
                    : const Align(
                        alignment: Alignment.centerLeft,
                        child: QuickOpenButton(),
                      ),
              ),
            ),
            // The terminal's own verbs, acting on the pane the keyboard is in.
            // Not per group: seven repeated in every strip made a split group
            // narrower than its own status bar. Down to `+` at compact widths.
            TerminalToolbar(compact: width.isCompact),
            const _WindowSessionBadges(),
            _ChromeToggle(
              icon: AppIcons.arrowsOutSimple,
              label: 'Focus mode',
              chord: shellChordLabel<ToggleFocusModeIntent>(),
              note: 'Hides the Explorer and the side panel',
              selected: ref.watch(terminalMaximizedProvider),
              onPressed: () =>
                  ref.read(terminalMaximizedProvider.notifier).toggle(),
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
              onPressed: () => openSettingsTab(ref),
            ),
          ],
        ),
      ),
    );
  }
}

/// What is running that no group's strip can show: sessions a restart left
/// dormant, and sessions kept alive with no tab. Both are facts about the
/// **window**, which is why they are answered here once and not per group.
class _WindowSessionBadges extends ConsumerWidget {
  const _WindowSessionBadges();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final actions = TerminalActions(ref);
    final restored = ref.watch(
      restoredAgentPanesProvider.select((panes) => panes.length),
    );
    final background = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.detached.length),
    );
    if (restored == 0 && background == 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (restored > 0)
          IconButton(
            tooltip:
                '$restored restored session'
                '${restored == 1 ? '' : 's'} — nothing running in '
                '${restored == 1 ? 'it' : 'them'}',
            icon: Badge.count(
              count: restored,
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
              // Not the history clock the Commands button uses: two identical
              // icons in one row are one icon as far as the eye is concerned.
              child: const Icon(AppIcons.playCircle, size: Chrome.icon),
            ),
            onPressed: () => actions.showRestoredSessions(context),
          ),
        if (background > 0)
          IconButton(
            tooltip:
                '$background session'
                '${background == 1 ? '' : 's'} running in the background',
            // The accent, not Material's error red: a session running without a
            // tab is the app working as designed, not a fault.
            icon: Badge.count(
              count: background,
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
              child: const Icon(AppIcons.terminalWindow, size: Chrome.icon),
            ),
            onPressed: () => actions.showBackgroundSessions(context),
          ),
      ],
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

  /// The menu titles sit at the tab chips' size, weight and colour: they are
  /// chrome, not a heading over it, so full contrast only under the pointer.
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
            icon: const Icon(AppIcons.arrowsClockwise),
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
              shortcut: commandActivator(
                LogicalKeyboardKey.keyN,
                shift: true,
              ),
              onPressed: () => NewProjectDialog.show(context),
              child: const Text('New project'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.chatCircleDots),
              shortcut: commandActivator(LogicalKeyboardKey.keyN),
              // Never disabled: the dialog chooses where the session runs, so
              // it no longer needs the app to be pointed anywhere first.
              onPressed: () => NewSessionDialog.show(context),
              child: const Text('New session'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.magnifyingGlass),
              shortcut: commandActivator(LogicalKeyboardKey.keyK),
              onPressed: () => QuickOpen.show(context),
              child: const Text('Go to…'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              // `globe` is the Browser surface; scanning the CLI stores for
              // sessions is a search, not the web.
              leadingIcon: const Icon(AppIcons.listMagnifyingGlass),
              // No chord: this is the scan you run a handful of times in a
              // workspace's life, and every chord left is one a shell can use.
              onPressed: () => _showDetected(context, ref),
              child: const Text('Detect CLI sessions'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.arrowsClockwise),
              // Unbound on purpose: rare *and* half destructive is the shape of
              // thing that should cost a deliberate trip through a menu.
              onPressed: () => _clearAndReimport(context, ref),
              child: const Text('Clear projects and re-import'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.power),
              // ⌘Q on macOS only, and written out rather than reached through
              // `commandActivator`, because off a Mac this must not become
              // Ctrl+Q, which is XON. `performKeyEquivalent` catches the real
              // ⌘Q ahead of the Flutter view; this item is only its label.
              shortcut: commandKeyIsMeta
                  ? const SingleActivator(LogicalKeyboardKey.keyQ, meta: true)
                  : null,
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
              shortcut: commandActivator(
                LogicalKeyboardKey.keyB,
                shift: true,
              ),
              onChanged: (_) => ref
                  .read(shellControllerProvider.notifier)
                  .toggleExplorerPane(),
              child: const Text('Explorer'),
            ),
            CheckboxMenuButton(
              value: panel != null,
              shortcut: commandActivator(LogicalKeyboardKey.digit3),
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
                // The inbox already had this chord and the menu never said so.
                // The others stay bare: a dozen more chords is a dozen more
                // keys taken from every shell in the app.
                shortcut: surface == SidePanelSurface.inbox
                    ? commandActivator(LogicalKeyboardKey.keyA, shift: true)
                    : null,
                onPressed: () =>
                    ref.read(sidePanelProvider.notifier).select(surface),
                child: Text(surface.label),
              ),
            const Divider(height: 1),
            CheckboxMenuButton(
              value: zen,
              shortcut: commandActivator(LogicalKeyboardKey.backslash),
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
              // `Ctrl+,` / `⌘,` is the settings chord on every platform, and
              // unlike most Ctrl keys it is not one a shell claims.
              shortcut: commandActivator(LogicalKeyboardKey.comma),
              onPressed: () => openSettingsTab(ref),
              child: const Text('Settings'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              leadingIcon: const Icon(AppIcons.info),
              // No chord: a dialog you open once, to copy a build line into a
              // bug report.
              onPressed: () => KarmashalaAboutDialog.show(context),
              child: const Text('About Karmashala'),
            ),
          ],
          child: const Text('Tools'),
        ),
      ],
    );
  }
}
