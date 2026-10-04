import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'ask_toasts.dart';
import 'narrow_overlay.dart';
import 'phone_shell.dart';
import 'zen_bar.dart';
import 'resize_handle.dart';
import 'side_panel.dart';
import 'side_panel_state.dart';
import 'workbench.dart';

import '../../core/data/data_providers.dart';
import '../../core/data/metadata_keys.dart';
import '../../core/lifecycle/before_quit.dart';
import '../../features/automations/application/resume_announcer.dart';
import '../../features/automations/application/scheduled_resume_observer.dart';
import '../../features/automations/application/usage_limit_notices.dart';
import '../../features/automations/presentation/resume_on_reset_dialog.dart';
import '../../features/editor/application/editor_auto_save.dart';
import '../../features/editor/presentation/editor_close_guard.dart';
import '../../features/sessions/application/quit_resume_launch.dart';
import '../../features/sessions/application/server_session_notices.dart';
import '../../features/sessions/presentation/quit_sessions_dialog.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/onboarding/application/quick_start.dart';
import '../../features/terminal/application/client_intents.dart';
import '../../features/terminal/application/client_presence.dart';
import '../../features/notes/application/note_tabs.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/sessions/application/pending_live_switches.dart';
import '../../features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import '../../features/agents/application/agent_model_catalog_providers.dart';
import '../../features/sessions/application/session_launch_refusal.dart';
import '../../features/sessions/application/session_handoff_service.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'quick_open/quick_open.dart';
import 'shell_shortcuts.dart';
import 'activity_strip.dart';
import 'shell_sidebar.dart';
import 'shell_state.dart';
import 'shell_title_bar.dart';

export 'shell_title_bar.dart' show ShellTitleBar;

/// Width classes for the desktop shell, in one place (see `CLAUDE.md` §6):
/// branching on width, never platform, is what keeps "responsive" a property.
/// The breakpoints are the UI overhaul spec's (§5, "Narrow and Zen").
enum ShellWidth {
  /// Under 600: the phone shell ([PhoneShell]), with a bottom bar and a host
  /// switcher on top. Inside the desktop layout (a safe area can take it
  /// under 600), an area or the context panel opens full width.
  compact,

  /// 600–839: the strip stays, but the sidebar and the context panel open
  /// over the workbench as sheets — there is no width left to share.
  medium,

  /// 840 and up: sidebar, workbench and context panel side by side. An open
  /// panel gets what the workbench floor leaves, or is not drawn
  /// (see [ShellLayout]).
  expanded;

  static const compactBelow = 600.0;
  static const mediumBelow = 840.0;

  static ShellWidth of(double width) {
    if (width < compactBelow) return ShellWidth.compact;
    if (width < mediumBelow) return ShellWidth.medium;
    return ShellWidth.expanded;
  }

  bool get isCompact => this == ShellWidth.compact;

  /// Whether the sidebar and the context panel are sheets over the workbench
  /// rather than columns beside it.
  bool get overlays => this != ShellWidth.expanded;
}

/// The desktop shell (UI overhaul spec §4): title bar, activity strip,
/// sidebar and workbench, with the context panel on demand and no global
/// status bar. Terminal-primary, so the terminal is the middle of the window,
/// not a dock.
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

  /// The width class the last layout found; null before the first.
  ShellWidth? _widthClass;

  /// What the side-by-side layout had open when the window narrowed, given
  /// back when it widens again. Narrowing folds both (spec §5: "the sidebar
  /// folds"): a sidebar left open would land on top of the workbench the
  /// moment the window crossed a breakpoint, which nobody asked for.
  bool _wideSidebarOpen = true;
  SidePanelSurface? _widePanel;

  bool get _overlays => _widthClass?.overlays ?? false;

  /// Notes the width class of this layout and, on crossing between side by
  /// side and sheets, folds or restores the sidebar and panel after the frame
  /// (a provider cannot be written mid-build). Returns whether this layout is
  /// the one that folds them, so it can draw them closed already.
  bool _trackWidthClass(ShellWidth next) {
    final previous = _widthClass;
    _widthClass = next;
    if (previous == next) return false;
    final folding = next.overlays && !(previous?.overlays ?? false);
    final unfolding = !next.overlays && (previous?.overlays ?? false);
    if (!folding && !unfolding) return false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sidebarOpen = ref.read(shellControllerProvider).explorerPaneVisible;
      final shell = ref.read(shellControllerProvider.notifier);
      final panel = ref.read(sidePanelProvider.notifier);
      if (folding) {
        _wideSidebarOpen = sidebarOpen;
        _widePanel = ref.read(sidePanelProvider);
        if (sidebarOpen) shell.toggleExplorerPane();
        if (_widePanel != null) panel.collapse();
      } else {
        if (sidebarOpen != _wideSidebarOpen) shell.toggleExplorerPane();
        if (_widePanel case final surface?
            when ref.read(sidePanelProvider) == null) {
          panel.show(surface);
        }
        _widePanel = null;
      }
    });
    return folding;
  }

  /// Closes the sheets over the workbench — the answer to Esc, a click
  /// outside, or a pick that sends the user to the workbench. Does nothing
  /// side by side, where nothing covers anything.
  void _dismissSheets({bool sidebar = true, bool panel = true}) {
    if (!_overlays) return;
    if (sidebar && ref.read(shellControllerProvider).explorerPaneVisible) {
      ref.read(shellControllerProvider.notifier).toggleExplorerPane();
    }
    if (panel && ref.read(sidePanelProvider) != null) {
      ref.read(sidePanelProvider.notifier).collapse();
    }
  }

  /// Sheets take turns: two at once would leave the workbench a sliver
  /// between them, so opening one closes the other.
  void _listenForSheets() {
    ref.listen(shellControllerProvider.select((s) => s.explorerPaneVisible), (
      was,
      open,
    ) {
      if (was == false && open) _dismissSheets(sidebar: false);
    });
    ref.listen(sidePanelProvider, (was, now) {
      if (was == null && now != null) _dismissSheets(panel: false);
    });
    // A pick that sends the user to the workbench — a row, a tab, the chord
    // that hands focus back — is done with the sidebar, so it folds again.
    ref.listen(shellControllerProvider.select((s) => s.focusedPane), (_, pane) {
      if (pane == ShellPane.detail) _dismissSheets(panel: false);
    });
    ref.listen(selectedSessionIdProvider, (_, _) {
      _dismissSheets(panel: false);
    });
    ref.listen(
      terminalSessionsControllerProvider.select(
        (s) => (s.activeTab?.id, s.activeTab?.focusedPaneId),
      ),
      (_, _) => _dismissSheets(),
    );
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
      final preferences = ref.read(appPreferencesProvider);
      if (preferences.read(MetadataKeys.environmentHealthOnboarding) !=
          'pending') {
        return;
      }
      preferences.write(MetadataKeys.environmentHealthOnboarding, 'shown');
      // Not a dialog over the terminal: the quick start opens in the sidebar
      // and the machine is checked, read-only, beside it.
      ref.read(quickStartProvider.notifier).beginFirstRun();
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
    // nothing listens, so a reporter nobody watches never hears a pane stop.
    ref.watch(refusedLaunchReporterProvider);
    // And a session starting, which re-reads its agent's list of models.
    ref.watch(agentModelsRefresherProvider);
    // And for this machine's host feed, the status of every hosted session.
    ref.watch(hostLifecycleSubscriberProvider);
    // And for a model picked mid-turn, which is sent when the turn ends.
    ref.watch(pendingLiveSwitchesProvider);
    // Same reason: what the server asks this window to show, and the
    // presence that makes it this window it asks.
    ref.watch(clientIntentsProvider);
    ref.watch(clientPresenceProvider);
    // And for scheduled resumes.
    ref.watch(scheduledResumeObserverProvider);
    // And for a resume the server ended, which is announced here.
    ref.watch(serverResumeEndingsProvider);
    // And for a usage limit the server noticed, whose notice is shown here.
    ref.watch(usageLimitNoticesProvider);
    // And for what the server has to say of a session it delivered to.
    ref.watch(serverSessionNoticesProvider);
    // And for note tabs, which close with their note and flush on the way out.
    ref.watch(noteTabsObserverProvider);
    // And for an agent switched from another client, whose old terminal
    // here goes.
    ref.watch(sessionSwitchFollowerProvider);
    // And for file autosave, whose window-focus trigger has to be heard while
    // no editor tab is on screen. Listened rather than watched: its state is a
    // tab's business, not the shell's.
    ref.listen(editorAutoSaveProvider, (_, _) {});
    _listenForSheets();
    // Zen: the workbench takes the window.
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
    // A phone-width window gets the phone shell (Stage 1 step 7). Everything
    // above stays watched, and the shortcuts keep their state, across a
    // rotation between the two.
    if (ShellWidth.of(MediaQuery.sizeOf(context).width).isCompact) {
      _trackWidthClass(ShellWidth.compact);
      return const ShellShortcuts(child: PhoneShell());
    }
    // The macOS menu bar is mounted above this, in `KarmashalaApp`.
    return ShellShortcuts(
      child: Scaffold(
        // The bar's height follows the text scale (menus must not clip at
        // 125%+), and `preferredSize` cannot read a context.
        // Zen is only the pane (spec §5): the title bar goes with the rest,
        // and a small bar floats in at the top edge instead.
        appBar: zen ? null : ShellTitleBar(height: Chrome.titleBarOf(context)),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = ShellWidth.of(constraints.maxWidth);
              final folding = _trackWidthClass(width);
              final overlays = width.overlays;
              // The strip is there outside Zen, except at compact
              // widths, where it is a menu in the title bar; what is left is
              // what the sidebar, workbench and panel share.
              final stripShown = !zen && !width.isCompact;
              final available =
                  constraints.maxWidth - (stripShown ? kActivityStripWidth : 0);
              // Drawn closed on the layout that folds them, so a narrowing
              // window never flashes a sheet it is about to take away.
              final sidebarOpen = !folding && shell.explorerPaneVisible;
              // Measured as if Zen were off: it hides the panel too,
              // and leaving it must not find the selection dropped. A sheet
              // needs only its own minimum; a column needs the floor beside.
              final panelFits = overlays
                  ? available >= ShellLayout.panelMin
                  : ShellLayout.panelFits(
                      available: available,
                      explorerColumn: shell.explorerPaneVisible,
                    );
              _reportPanelRoom(panelFits);
              final panelOpen =
                  !zen && !folding && SidePanel.openSurface(ref) != null;
              final layout = ShellLayout.allocate(
                available: available,
                explorerColumn: !zen && !overlays && sidebarOpen,
                panelOpen: !overlays && panelOpen,
                explorerWidth: _explorerDrag ?? explorerWidth,
                panelWidth: _panelDrag ?? panelWidth,
              );
              final row = Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (stripShown) const ShellActivityStrip(),
                  if (!zen && !overlays && sidebarOpen)
                    ResizableColumn(
                      width: layout.explorerWidth!,
                      semanticLabel: 'Resize sidebar width',
                      onResize: (value) => setState(
                        () => _explorerDrag = layout.clampExplorer(value),
                      ),
                      onResizeEnd: _saveExplorerWidth,
                      child: const ShellSidebar(),
                    ),
                  // Keyed, so a strip or a column coming and going around it
                  // moves the workbench rather than building a new one.
                  const Expanded(
                    key: ValueKey('shell-workbench'),
                    child: WorkbenchView(),
                  ),
                  if (!zen && !overlays)
                    SidePanel(
                      bodyWidth: layout.panelWidth,
                      hasRoom: panelFits,
                      onResize: (value) =>
                          setState(() => _panelDrag = layout.clampPanel(value)),
                      onResizeEnd: _savePanelWidth,
                    ),
                ],
              );
              return Stack(
                children: [
                  Positioned.fill(child: row),
                  if (!zen && overlays)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      left: stripShown ? kActivityStripWidth : 0,
                      right: 0,
                      child: _sheets(
                        compact: width.isCompact,
                        available: available,
                        sidebarOpen: sidebarOpen,
                        panelOpen: panelOpen && panelFits,
                        explorerWidth: _explorerDrag ?? explorerWidth,
                        panelWidth: _panelDrag ?? panelWidth,
                      ),
                    ),
                  // Asks from sessions not on screen float at the
                  // workbench's top right corner (board N1), clear of the
                  // docks and status lines at the bottom — and above a
                  // sheet, because an ask still reaches you at every width.
                  // Each toast brings its own [Insets.sm] above it; in Zen
                  // they start under the floating bar, not across it.
                  Positioned(
                    right: Insets.lg,
                    top: zen ? kZenBarRoom : Insets.xs,
                    child: const ShellAskToasts(),
                  ),
                  if (zen)
                    const Positioned(
                      top: Insets.sm,
                      left: 0,
                      right: 0,
                      child: Center(child: ShellZenBar()),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The workbench width a medium sheet always leaves uncovered on its far
  /// side: a strip of the workbench to click back to, and a reminder it is
  /// still there.
  static const _sheetClearance = Insets.xxl * 2;

  /// The sidebar and the context panel as sheets over the workbench (spec §5).
  /// Medium: each at its saved width, still resizable, capped to leave
  /// [_sheetClearance] of workbench showing. Compact: full width — one column.
  Widget _sheets({
    required bool compact,
    required double available,
    required bool sidebarOpen,
    required bool panelOpen,
    required double explorerWidth,
    required double panelWidth,
  }) {
    double fit(double wanted, double least, double most) {
      final cap = (available - _sheetClearance).clamp(least, most);
      return wanted.clamp(least, cap);
    }

    final sidebarWidth = compact
        ? available
        : fit(explorerWidth, ShellLayout.explorerMin, ShellLayout.explorerMax);
    final panelBody = compact
        ? available
        : fit(panelWidth, ShellLayout.panelMin, ShellLayout.panelMax);
    return Stack(
      children: [
        if (sidebarOpen || panelOpen)
          Positioned.fill(child: ShellOverlayScrim(onDismiss: _dismissSheets)),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: sidebarWidth,
          child: ShellSlideOver(
            open: sidebarOpen,
            fromStart: true,
            onDismiss: () => _dismissSheets(panel: false),
            child: compact
                ? const ShellSidebar()
                : ResizableColumn(
                    width: sidebarWidth,
                    semanticLabel: 'Resize sidebar width',
                    onResize: (value) => setState(
                      () => _explorerDrag = fit(
                        value,
                        ShellLayout.explorerMin,
                        ShellLayout.explorerMax,
                      ),
                    ),
                    onResizeEnd: _saveExplorerWidth,
                    child: const ShellSidebar(),
                  ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: panelBody,
          child: ShellSlideOver(
            open: panelOpen,
            fromStart: false,
            // The panel draws nothing once collapsed; see [animateOut].
            animateOut: false,
            onDismiss: () => _dismissSheets(sidebar: false),
            child: SidePanel(
              bodyWidth: panelOpen ? panelBody : null,
              onResize: compact
                  ? null
                  : (value) => setState(
                      () => _panelDrag = fit(
                        value,
                        ShellLayout.panelMin,
                        ShellLayout.panelMax,
                      ),
                    ),
              onResizeEnd: compact ? null : _savePanelWidth,
            ),
          ),
        ),
      ],
    );
  }
}

/// How the shell's width is shared out. The workbench's floor is met first,
/// then the context panel's width, then the sidebar's; a panel that cannot
/// fit beside the floor is not drawn rather than crush the workbench.
@immutable
class ShellLayout {
  const ShellLayout._({
    required this.explorerWidth,
    required this.explorerMaxWidth,
    required this.panelWidth,
    required this.panelMaxWidth,
  });

  /// The least the workbench is given beside an open sidebar and context panel.
  static const workbenchFloor = 360.0;

  static const explorerMin = 200.0;
  static const explorerMax = 560.0;
  static const panelMin = 240.0;
  static const panelMax = 620.0;

  /// The sidebar column's width; null when there is no column to size. Named
  /// `explorer` for the panel the sidebar replaced; the settings keys kept it.
  final double? explorerWidth;
  final double explorerMaxWidth;

  /// The context panel's width; null when it is not drawn.
  final double? panelWidth;
  final double panelMaxWidth;

  /// [available] is the whole shell row after the strip. [explorerWidth] and
  /// [panelWidth] are the widths asked for, typically the saved ones.
  factory ShellLayout.allocate({
    required double available,
    required bool explorerColumn,
    required bool panelOpen,
    required double explorerWidth,
    required double panelWidth,
  }) {
    const handle = ResizeHandle.thickness;
    final room = available - workbenchFloor;
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

  /// Whether an open context panel would get a body beside the workbench floor.
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
