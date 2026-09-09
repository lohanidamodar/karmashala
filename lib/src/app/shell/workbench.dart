import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import '../widgets/desktop_dialog.dart';

import 'package:agent_cli/descriptors.dart';
import '../../features/agents/presentation/usage_chip.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/cli_detection/presentation/imported_session_view.dart';
import '../../features/explorer/application/explorer_actions.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/sessions/application/delivery_providers.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_status_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/sessions/presentation/session_notice_line.dart';
import '../../features/sessions/presentation/delivery_strip.dart';
import '../../features/sessions/presentation/model_chip.dart';
import '../../features/sessions/presentation/permission_mode_chip.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/terminal/application/terminal_presets.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/domain/document_pane.dart';
import '../../features/terminal/domain/pane_layout.dart';
import '../../features/terminal/domain/pane_liveness.dart';
import '../../features/terminal/domain/terminal_drag.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/presentation/close_tabs_dialog.dart';
import '../../features/terminal/presentation/empty_pane_region.dart';
import '../../features/terminal/presentation/pane_layout_view.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';
import 'tab_picker.dart';
import 'workbench_tabs.dart';
import 'tab_strip_metrics.dart';

// The strip's uniform-extent rule lives beside the strip's other consumers —
// a region header shares it. Re-exported so `workbench.dart` is still the one
// import anything about the tab strip needs.
export 'tab_strip_metrics.dart';

// The verbs that open and switch a workbench tab moved out so a feature
// widget can reach them without importing the whole workbench back. Still
// exported here, because this is the file the strip's callers already import.
export 'workbench_tabs.dart';

// The workbench's widgets, split into one file per family. They are `part`s
// rather than libraries of their own because privacy in Dart is per library:
// every widget below is private and the tree golden records those names, so
// moving one anywhere else would mean renaming it. What stays here is the
// composition — the view, what it listens to, and the verb that reveals the
// pane a session is running in.
part 'workbench_group.dart';
part 'workbench_surface.dart';
part 'workbench_session_bar.dart';
part 'workbench_strip.dart';
part 'workbench_strip_chip.dart';
part 'workbench_strip_drag.dart';
part 'workbench_tab_entries.dart';

/// The switcher between the two surfaces. Named so a test can read which one is
/// painted on a given frame without going through whatever either one renders.
const Key kWorkbenchSurfaces = ValueKey('workbench-surfaces');

/// The primary content area: one tab strip across the top, the work underneath.
///
/// Loop 47 moved the terminal here from a 280px bottom dock. A dock is right for
/// an *editor*-primary app; Karmashala decided to be terminal-primary, and none
/// of the products it is learning from (Orca, cmux, Warp, Ghostty) put the
/// terminal anywhere but the middle of the window.
///
/// **One session, two views.** A session that runs in one of our panes is not
/// two things. Its chat rendering and its terminal are two surfaces of the same
/// record, switched by the toggle at the right of the bar beneath them — which
/// is why the switch reattaches and focuses rather than starting anything.
/// Which surface is showing is [terminalVisibleProvider]: `true` is the
/// terminal, `false` is the conversation. Nothing else needed a new provider.
///
/// **The strip is tabs; the bar is this session.** A selection used to add a
/// conversation *tab* as well as offer the toggle, so one tap in the Explorer
/// grew a second tab and a switch that did the same job — and the permission
/// chip sat up in the strip while every other session control was under the
/// terminal. There is no conversation tab any more, and everything that belongs
/// to the session on screen is in [_SessionBar]: the window reads chrome, work,
/// chrome.
///
/// **The terminal is the one you land on.** Until Loop 85 selecting a session
/// switched the workbench to its *chat*, which made the secondary view the
/// default one and left every session action (handoff, fork, the delivery
/// lifecycle) reachable only from there. Now a selection opens the session's pane, and those controls are
/// composed around it from the same widgets the conversation uses — see
/// [_SessionBar]. Chat is one labelled tap, or `` Ctrl+` ``, away.
///
/// **Nothing here ever switches itself to chat.** Loop 85 landed a session on
/// the terminal *when it had a pane* and fell back to the conversation when it
/// did not; Loop 86 kept the fallback and re-asked the question whenever a pane
/// arrived. Both left the tap deciding "chat" first and something else undoing
/// it, and every outcome where nothing undid it — a row whose CLI id we never
/// learned, an agent that refuses a second writer, a launch that threw — landed
/// on the conversation for good. So a tap opened the chat interface, or a
/// terminal, depending on the row. The rule is now unconditional: **a selection
/// shows the session's terminal**, and `terminalVisibleProvider` is set to
/// `false` in exactly one place — the labelled Chat half of [_ViewToggle],
/// which `` Ctrl+` `` also reaches.
///
/// A session with no pane of ours is not a reason to show something else: the
/// terminal surface draws [_NoPaneForSession] for it, which names the session,
/// says nothing of ours is running it and offers the two honest ways on. That
/// keeps "always the terminal" from meaning "somebody else's terminal tab".
///
/// **What the selection is for, though, is asking to see a session.** Ending
/// one is the opposite, so the empty state is not the answer to it: the
/// selection is released instead and the user lands on whatever the terminal
/// still has. See [_releaseEndedPane], and [releaseHijackedSelection] for the
/// other gesture that means the same thing.
class WorkbenchView extends ConsumerStatefulWidget {
  const WorkbenchView({super.key});

  @override
  ConsumerState<WorkbenchView> createState() => _WorkbenchViewState();
}

class _WorkbenchViewState extends ConsumerState<WorkbenchView> {
  /// The pane the workbench last opened the selected session on, or null when
  /// it had none. What [_followSessionPane] compares against, so a terminal
  /// publish that changes nothing about *this* session costs one lookup.
  String? _shownPane;

  /// Whether the one automatic open has had its turn.
  ///
  /// Owned here rather than by the pane stack: the stack is rebuilt whenever
  /// the workspace gains or loses its last tab, so a flag that lived down there
  /// would reset and reopen the terminal the user has just closed.
  bool _autoOpenDone = false;

  @override
  void initState() {
    super.initState();
    // There is always at least one terminal when the workbench opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final terminal = TerminalActions(ref);
      if (ref.read(terminalSessionsControllerProvider).isEmpty) {
        terminal.open(terminal.defaultProfile());
      }
      // Deliberately not conditional on having opened anything: what this
      // records is that the automatic attempt is over, so a workspace that
      // stays empty offers the user the button instead of a false promise.
      setState(() => _autoOpenDone = true);
    });
    // A session can already be selected when the workbench mounts — the shell
    // rebuilding around it, or a selection made by something that ran first.
    // The listener in `build` only fires on a *change*, so the mount has to
    // catch up by hand. There is no first-frame flash to guard against any
    // more: nothing below ever writes `false`, and the provider rests on
    // `true`, so the frame this defers past already shows the terminal.
    final selected = ref.read(selectedSessionIdProvider);
    final active = ref.read(activePaneSessionIdProvider);
    if (selected == null && active == null) return;
    if (selected != null) _shownPane = sessionTerminalPane(ref, selected);
    // Riverpod forbids writing a provider from `initState`, and reattaching a
    // pane there would republish the terminal while the tree is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A restored layout can put an agent pane on screen before anything is
      // selected; the side panel should describe that session, not the row the
      // Explorer happens to highlight first.
      if (active != null) ref.read(sessionContextProvider).follow(active);
      if (selected != null) _showSurfaceFor(_shownPane, selected);
      _hostSelection();
    });
  }

  /// Records the group the Explorer's selection has been opened into — the one
  /// with the keyboard, because that is what a tap in the tree means.
  ///
  /// Only ever *recorded*. Which group draws the selection is then a fact about
  /// that group, so moving the keyboard afterwards moves nothing on screen —
  /// see [selectionHostGroupProvider].
  void _hostSelection() {
    final selected =
        ref.read(selectedSessionIdProvider) ??
        ref.read(selectedImportedSessionIdProvider);
    ref
        .read(selectionHostGroupProvider.notifier)
        .host(selected == null ? null : ref.read(focusedWorkspaceGroupProvider));
  }

  /// Reveals the pane [sessionId] is already running in. Starts and stops
  /// nothing: a detached pane comes back as a tab, one already in a tab is
  /// simply focused.
  ///
  /// [sessionId] is carried alongside the pane purely to **name the change**.
  /// This used to publish a placement change with no row on it, and a change
  /// that names no row is read — correctly — as being about every row, so one
  /// switch woke every per-session provider in the app: at a screenful of
  /// Explorer cards that is five rebuilds and a handful of reads per row, for a
  /// session nothing happened to. Every caller knows whose pane this is, so it
  /// says so. Measured in `session_switch_cost_test.dart`.
  void _showTerminalFor(String? paneId, String? sessionId) =>
      showTerminalFor(ref, paneId, sessionId);

  /// Opens [sessionId] on the surface a session *is*: its terminal.
  ///
  /// No branch on whether it has a pane. `sessionTerminalPane` is still asked,
  /// but only to decide *which* pane to focus — a session that has none gets
  /// the terminal surface with [_NoPaneForSession] on it, which is the one
  /// place that says so, in the same words the conversation's own empty hint
  /// reads off the same helper.
  void _openSession(String sessionId) =>
      _showSurfaceFor(sessionTerminalPane(ref, sessionId), sessionId);

  /// Follows the selected session onto the pane it acquires, or loses.
  ///
  /// The Explorer selects a row **before** it reveals or resumes it, so at the
  /// moment of the tap a session being brought back has no pane yet; the pane
  /// that arrives a moment later has to be focused or the terminal on screen
  /// would be some other session's. Both inputs are watched: the terminal's own
  /// state (a pane created, adopted, restored, detached or ended) and
  /// `sessions.pane_id` (which a launch rewrites, then bumps the revision).
  ///
  /// Memoised on [_shownPane], so a publish about some other session costs one
  /// lookup — and, because this no longer chooses a *surface*, a user who has
  /// deliberately switched to the conversation is not thrown back to the
  /// terminal by a pane appearing somewhere else.
  void _followSessionPane() {
    final sessionId = ref.read(selectedSessionIdProvider);
    if (sessionId == null) return;
    final paneId = sessionTerminalPane(ref, sessionId);
    if (paneId == _shownPane) return;
    // A session that *had* a pane and no longer has one has been ended — which
    // is a different act from selecting a session that never had one, and only
    // the first is a reason to move the user off it. See [_releaseEndedPane].
    final ended = _shownPane != null && paneId == null;
    _shownPane = paneId;
    // Gaining a pane moves the workbench onto it, or the session would be off
    // screen.
    if (paneId != null) {
      _showTerminalFor(paneId, sessionId);
    } else if (ended) {
      _releaseEndedPane();
    }
  }

  /// Lets go of the selected session once the pane it was being shown in has
  /// been taken away.
  ///
  /// Ending a session is an explicit "I am done with this", so the workbench
  /// must not park the user on [_NoPaneForSession] — a tombstone for the thing
  /// they just finished with — while live tabs sit behind it. That was the
  /// report: *"when i end session why show this, why not switch to another
  /// existing tab and show empty if no other tabs exist?"*.
  ///
  /// Releasing the selection is the whole move. [TerminalSessionsController]
  /// already hands the active tab to the neighbour when the active one closes,
  /// the way every tab strip does, and with nothing selected the workbench
  /// draws whatever the terminal has — that neighbour, or the empty workbench
  /// when the ended session was the last tab.
  ///
  /// **Cleared, not out-voted**, for the reason [releaseHijackedSelection]
  /// gives: `null` is the one value the selection listeners in [build] ignore,
  /// so writing the neighbour's session id here would restart the fight where
  /// a tap opens a session's terminal and something else undoes it.
  ///
  /// Only while the terminal is the surface up. On the conversation the empty
  /// state is not in the way — and letting the selection go there would hand
  /// the reader whichever session the neighbouring tab happens to run, which
  /// is the wrong transcript rather than a tidier one.
  void _releaseEndedPane() {
    if (!ref.read(terminalVisibleProvider)) return;
    ref.read(selectedSessionIdProvider.notifier).select(null);
  }

  void _showSurfaceFor(String? paneId, String? sessionId) {
    _shownPane = paneId;
    _showTerminalFor(paneId, sessionId);
  }

  @override
  Widget build(BuildContext context) {
    // Picking a session in the Explorer is a request to *work in* it, and the
    // session is its terminal. Kept as a listener rather than a build-time
    // branch so the user can switch to the conversation and stay there.
    ref.listen(selectedSessionIdProvider, (_, next) {
      if (next != null) _openSession(next);
      // After the open, so the group recorded is the one the session landed
      // in rather than the one the keyboard was in a moment earlier.
      _hostSelection();
    });
    ref.listen(selectedImportedSessionIdProvider, (_, next) {
      // An imported CLI session has no pane of ours *yet* — the tap that
      // selected it is already resuming it into one (`openImported`). This used
      // to switch straight to the transcript, which is how the one path the
      // user could not miss opened the chat interface every single time.
      if (next != null) _showSurfaceFor(null, null);
      _hostSelection();
    });
    // ...and the pane the selected session has can arrive after the tap that
    // selected it, or go away under it. Both of these move it: the terminal's
    // state says whether an instance exists, the revision says which pane the
    // row points at. See [_followSessionPane].
    ref.listen(terminalSessionsControllerProvider, (_, _) {
      _followSessionPane();
    });
    // Only where sessions live. A row being renamed cannot move the pane the
    // workbench is following, and used to re-run this on every title sync.
    ref.listen(
      sessionSignalsProvider.select(
        (signals) => signals.forKinds(const {
          SessionChangeKind.membership,
          SessionChangeKind.placement,
        }),
      ),
      (_, _) => _followSessionPane(),
    );
    // The side panel describes the session you are in. Driven by the pane on
    // screen rather than by the selection, so activating another terminal tab
    // moves the changes, worktree and GitHub surfaces with it; a tab with no
    // session writes nothing and leaves the Explorer's choice alone.
    ref.listen(activePaneSessionIdProvider, (_, next) {
      final context = ref.read(sessionContextProvider);
      // A shell tab follows nothing, and saying so matters: a checkout picked
      // while one is up would otherwise be filed against whichever session was
      // followed last, and stick to it for the rest of the run.
      next == null ? context.stopFollowing() : context.follow(next);
    });

    final workspace = ref.watch(workspaceLayoutProvider);
    // Before the first tab there is no tree at all, and one group stands in for
    // it: an empty strip, a surface that says a terminal is on its way, and no
    // session to put a bar under.
    if (workspace == null) {
      return _WorkspaceGroup(groupId: null, autoOpenDone: _autoOpenDone);
    }
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return PaneLayoutView(
      layout: workspace,
      onResize: sessions.resizeWorkspace,
      regionBuilder: (group) => _WorkspaceGroup(
        // Keyed by group, so a collapsing group does not hand its element —
        // and the tabs mounted inside it — to whichever group takes its place.
        key: ValueKey(group.id),
        groupId: group.id,
        autoOpenDone: _autoOpenDone,
      ),
    );
  }
}

/// Reveals the pane [sessionId] is already running in. Starts and stops
/// nothing: a detached pane comes back as a tab, one already in a tab is
/// simply focused.
///
/// [sessionId] is carried alongside the pane purely to **name the change**.
/// This used to publish a placement change with no row on it, and a change
/// that names no row is read — correctly — as being about every row, so one
/// switch woke every per-session provider in the app: at a screenful of
/// Explorer cards that is five rebuilds and a handful of reads per row, for a
/// session nothing happened to. Every caller knows whose pane this is, so it
/// says so. Measured in `session_switch_cost_test.dart`.
void showTerminalFor(WidgetRef ref, String? paneId, String? sessionId) {
  if (paneId != null) {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    terminals
      ..reattachSession(paneId)
      ..focusPane(paneId);
    // Which pane this session is showing in moved, and nothing about any
    // other row. A pane with no session behind it — there is no such caller
    // today — would still be the honest broadcast.
    ref.publishSessionChange(
      sessionId == null
          ? const SessionChange(kinds: {SessionChangeKind.placement})
          : SessionChange.moved(sessionId),
    );
  }
  // The group that pane is in — not the focused one. A launch, a reveal or an
  // approval means "show me it *there*", and with two groups those are
  // different answers.
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  paneId == null
      ? terminals.showTerminalHere()
      : terminals.showTerminalForPane(paneId);
}
