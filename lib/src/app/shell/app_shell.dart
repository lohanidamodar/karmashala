import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'resize_handle.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';
import 'status_bar.dart';
import 'workbench.dart';

import '../../core/database/database_providers.dart';
import '../../core/lifecycle/before_quit.dart';
import '../../features/automations/application/automation_event_router.dart';
import '../../features/automations/application/automation_runner.dart';
import '../../features/automations/application/automation_scheduler.dart';
import '../../features/automations/application/scheduled_resume_observer.dart';
import '../../features/automations/application/usage_limit_watcher.dart';
import '../../features/automations/presentation/resume_on_reset_dialog.dart';
import '../../features/editor/application/editor_auto_save.dart';
import '../../features/editor/presentation/editor_close_guard.dart';
import '../../features/sessions/application/quit_resume_launch.dart';
import '../../features/sessions/presentation/quit_sessions_dialog.dart';
import '../../features/environments/presentation/environment_health_dialog.dart';
import '../../features/flutter_apps/application/flutter_gate_observer.dart';
import '../../features/git/application/worktree_setup_providers.dart';
import '../../features/notes/application/note_tabs.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/sessions/application/session_liveness_reconciler.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'quick_open/quick_open.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';
import 'shell_title_bar.dart';

export 'shell_title_bar.dart' show ShellTitleBar;

/// Width classes for the desktop shell, in one place (see `CLAUDE.md` §6):
/// branching on width, never platform, is what keeps "responsive" a property.
enum ShellWidth {
  /// One pane at a time, chosen with a selector. The side panel's rail stays —
  /// it is 34px and it is the only way back to the tools.
  compact,

  /// Explorer beside the workbench. An open side panel gets what the workbench
  /// floor leaves, or keeps only its rail (see [ShellLayout]).
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
  /// A width mid-drag. Persisted, and cleared, when the drag ends.
  double? _explorerDrag;
  double? _panelDrag;

  void _saveExplorerWidth() {
    final width = _explorerDrag;
    if (width == null) return;
    ref.read(settingsControllerProvider.notifier).setExplorerPaneWidth(width);
    setState(() => _explorerDrag = null);
  }

  void _savePanelWidth() {
    final width = _panelDrag;
    if (width == null) return;
    ref.read(settingsControllerProvider.notifier).setDetailSidebarWidth(width);
    setState(() => _panelDrag = null);
  }

  /// The shell is the only thing that knows the window's width, and a provider
  /// cannot be written mid-build, so the reading lands after the frame.
  void _reportPanelRoom(bool hasRoom) {
    if (ref.read(sidePanelRoomProvider) == hasRoom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(sidePanelRoomProvider.notifier).report(hasRoom);
    });
  }

  /// Removes the before-quit guards this shell registered.
  late final void Function() _removeQuitGuard;
  late final void Function() _removeSessionQuitGuard;

  @override
  void initState() {
    super.initState();
    // The shell holds the navigator a quit-time question needs.
    _removeQuitGuard = ref
        .read(beforeQuitHooksProvider)
        .addGuard(
          'unsaved work',
          () async =>
              !mounted || await confirmQuitWithUnsavedWork(context, ref),
        );
    // Registered after it, so the files question comes first: an answer about
    // unsaved edits is the one that cannot be taken back.
    _removeSessionQuitGuard = ref
        .read(beforeQuitHooksProvider)
        .addGuard(
          'running sessions',
          () async =>
              !mounted || await confirmQuitWithRunningSessions(context, ref),
        );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(reopenSessionsFromLastQuit(ref));
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
  void dispose() {
    _removeQuitGuard();
    _removeSessionQuitGuard();
    super.dispose();
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
    // And for scheduled resumes, which share that scheduler's one timer.
    ref.watch(scheduledResumeObserverProvider);
    // And for the turn that ends on a usage limit, which offers one.
    ref.watch(usageLimitWatcherProvider);
    // And for event automations, which hear status changes only while watched.
    ref.watch(automationEventRouterProvider);
    // And for note tabs, which close with their note and flush on the way out.
    ref.watch(noteTabsObserverProvider);
    // And for file autosave, whose window-focus trigger has to be heard while
    // no editor tab is on screen. Listened rather than watched: its state is a
    // tab's business, not the shell's.
    ref.listen(editorAutoSaveProvider, (_, _) {});
    // Focus mode: the workbench takes the window.
    final zen = ref.watch(terminalMaximizedProvider);
    final explorerWidth = ref.watch(
      settingsControllerProvider.select((s) => s.explorerPaneWidth),
    );
    final panelWidth = ref.watch(
      settingsControllerProvider.select((s) => s.detailSidebarWidth),
    );
    // The global hotkey summons the window with quick open up; the service that
    // registers it lives outside the tree, so it bumps a counter for the shell.
    ref.listen(quickOpenRequestProvider, (_, _) {
      if (mounted) QuickOpen.show(context);
    });
    // A limit notice's "Options…" is pressed in a bar that holds no dialog.
    ref.listen(resumeDialogRequestProvider, (_, request) {
      if (request == null || !mounted) return;
      ResumeOnResetDialog.show(
        context,
        request.sessionIds,
        namedWindow: request.namedWindow,
      );
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
              // in the same column.
              final showExplorer = width.isCompact
                  ? shell.focusedPane == ShellPane.explorer
                  : shell.explorerPaneVisible;
              // Measured as if focus mode were off: it hides the rail too, and
              // leaving it must not find the selection dropped.
              final panelFits = ShellLayout.panelFits(
                available: constraints.maxWidth,
                explorerColumn: showExplorer && !width.isCompact,
              );
              _reportPanelRoom(panelFits);
              final layout = ShellLayout.allocate(
                available: constraints.maxWidth,
                explorerColumn: !zen && showExplorer && !width.isCompact,
                panelOpen: !zen && SidePanel.openSurface(ref) != null,
                explorerWidth: _explorerDrag ?? explorerWidth,
                panelWidth: _panelDrag ?? panelWidth,
              );
              return Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!zen && showExplorer)
                          width.isCompact
                              ? const Expanded(child: ExplorerPanel())
                              : ResizableColumn(
                                  width: layout.explorerWidth!,
                                  semanticLabel: 'Resize Explorer width',
                                  onResize: (value) => setState(
                                    () => _explorerDrag = layout.clampExplorer(
                                      value,
                                    ),
                                  ),
                                  onResizeEnd: _saveExplorerWidth,
                                  child: const ExplorerPanel(),
                                ),
                        if (!width.isCompact || !showExplorer)
                          const Expanded(child: WorkbenchView()),
                        if (!zen)
                          SidePanel(
                            bodyWidth: layout.panelWidth,
                            hasRoom: panelFits,
                            onResize: (value) => setState(
                              () => _panelDrag = layout.clampPanel(value),
                            ),
                            onResizeEnd: _savePanelWidth,
                          ),
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
      height: Chrome.tabStripOf(context) + Insets.sm,
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

/// How the shell's width is shared out. The workbench's floor is met first,
/// then the side panel's width, then the Explorer's; a panel that cannot fit
/// beside the floor keeps only its rail rather than crush the workbench.
@immutable
class ShellLayout {
  const ShellLayout._({
    required this.explorerWidth,
    required this.explorerMaxWidth,
    required this.panelWidth,
    required this.panelMaxWidth,
  });

  /// The least the workbench is given beside an open Explorer and side panel.
  static const workbenchFloor = 360.0;

  static const explorerMin = 200.0;
  static const explorerMax = 560.0;
  static const panelMin = 240.0;
  static const panelMax = 620.0;

  /// The Explorer column's width; null when there is no column to size.
  final double? explorerWidth;
  final double explorerMaxWidth;

  /// The side panel body's width; null when only the rail is drawn.
  final double? panelWidth;
  final double panelMaxWidth;

  /// [available] is the whole shell row, rail included. [explorerWidth] and
  /// [panelWidth] are the widths asked for, typically the saved ones.
  factory ShellLayout.allocate({
    required double available,
    required bool explorerColumn,
    required bool panelOpen,
    required double explorerWidth,
    required double panelWidth,
  }) {
    const handle = ResizeHandle.thickness;
    final room = available - Chrome.rail - workbenchFloor;
    final explorerReserve = explorerColumn ? explorerMin + handle : 0.0;

    double? panel;
    var panelMaxWidth = panelMin;
    final panelRoom = room - explorerReserve - handle;
    if (panelOpen && panelRoom >= panelMin) {
      panelMaxWidth = panelRoom < panelMax ? panelRoom : panelMax;
      panel = panelWidth.clamp(panelMin, panelMaxWidth);
    }

    double? explorer;
    var explorerMaxWidth = explorerMin;
    if (explorerColumn) {
      final explorerRoom =
          room - handle - (panel == null ? 0.0 : panel + handle);
      explorerMaxWidth = explorerRoom.clamp(explorerMin, explorerMax);
      explorer = explorerWidth.clamp(explorerMin, explorerMaxWidth);
    }

    return ShellLayout._(
      explorerWidth: explorer,
      explorerMaxWidth: explorerMaxWidth,
      panelWidth: panel,
      panelMaxWidth: panelMaxWidth,
    );
  }

  /// Whether an open side panel would get a body beside the workbench floor.
  static bool panelFits({
    required double available,
    required bool explorerColumn,
  }) =>
      ShellLayout.allocate(
        available: available,
        explorerColumn: explorerColumn,
        panelOpen: true,
        explorerWidth: explorerMin,
        panelWidth: panelMin,
      ).panelWidth !=
      null;

  double clampExplorer(double width) =>
      width.clamp(explorerMin, explorerMaxWidth);

  double clampPanel(double width) => width.clamp(panelMin, panelMaxWidth);
}
