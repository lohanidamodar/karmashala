import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import '../widgets/desktop_dialog.dart';

import '../../features/agents/domain/agent_status.dart';
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

/// The insertion mark the strip draws while a tab is being dragged over it.
///
/// A drop that only announces itself by its result is a drop nobody aims: the
/// strip has to say *where this will land* while the button is still down, the
/// way every browser and editor does. Exactly one is ever on screen — a drag
/// has one active target at a time — so a test can find *the* mark and read its
/// rect to say which edge of which chip it is on.
const kTabDropMarker = Key('tab-strip/drop-marker');

/// The chip a pane will join, or a tab will divide the workspace beside.
///
/// A whole-chip mark rather than the edge caret [_markedForDrop] draws: neither
/// drop lands the thing *between* two chips, so an edge would be pointing at a
/// position that does not exist.
const kPaneJoinMarker = Key('tab-strip/pane-join-marker');
const kTabSplitMarker = Key('tab-strip/split-marker');

/// [child] under a tinted, outlined box carrying [icon].
Widget _markedForJoin(
  BuildContext context,
  Widget child, {
  required Key key,
  IconData icon = AppIcons.plus,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Stack(
    fit: StackFit.passthrough,
    children: [
      child,
      Positioned.fill(
        key: key,
        // A statement, not a target — the same reason [_markedForDrop] gives.
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.15),
              border: Border.all(color: scheme.primary, width: 2),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Center(
              child: Icon(icon, size: Chrome.iconSmall, color: scheme.primary),
            ),
          ),
        ),
      ),
    ],
  );
}

/// [child] with [kTabDropMarker] laid down its leading or trailing edge.
Widget _markedForDrop(
  BuildContext context,
  Widget child, {
  required bool leading,
}) => Stack(
  fit: StackFit.passthrough,
  children: [
    child,
    Positioned(
      key: kTabDropMarker,
      left: leading ? 0 : null,
      right: leading ? null : 0,
      top: 0,
      bottom: 0,
      width: 2,
      // The mark is a statement, not a target: a drag is hit-tested through
      // the avatar, and 2px of the chip that answered a pointer differently
      // while a drag was over it would be a control nobody meant to make.
      child: IgnorePointer(
        child: ColoredBox(color: Theme.of(context).colorScheme.primary),
      ),
    ),
  ],
);

/// The drop target on a tab chip: reorders tabs when dragged over, and splits
/// the tab when dropped with Ctrl held.
class _TabDropTarget extends ConsumerStatefulWidget {
  const _TabDropTarget({
    required this.index,
    required this.tab,
    required this.groupId,
    required this.chip,
  });

  final int index;
  final TerminalTab tab;

  /// The strip this chip is in. A tab from **another** group lands here as a
  /// move rather than a reorder — the drop that makes groups worth having.
  final String? groupId;

  final Widget chip;

  @override
  ConsumerState<_TabDropTarget> createState() => _TabDropTargetState();
}

class _TabDropTargetState extends ConsumerState<_TabDropTarget> {
  /// How near the middle of a chip counts as *on* it, in logical pixels.
  static const _centreSlack = 1.0;

  bool _dropLeading = true;
  bool _ctrlPressed = false;

  void _updatePosition(TerminalDrag data, Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      final offMiddle = box.globalToLocal(globalPos).dx - box.size.width / 2;
      // Which half the pointer is over says where the tab lands. Dead centre
      // is not a coin flip: it goes the way the drag came from, which is the
      // whole rule the strip had before it had halves.
      final leading = offMiddle.abs() <= _centreSlack
          ? _comesFromTheRight(data)
          : offMiddle < 0;
      final ctrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (leading != _dropLeading || ctrl != _ctrlPressed) {
        setState(() {
          _dropLeading = leading;
          _ctrlPressed = ctrl;
        });
      }
    }
  }

  bool _comesFromTheRight(TerminalDrag data) =>
      data is TabDrag && _indexInStrip(data.tabId) > widget.index;

  /// The region of this tab a dropped **pane** joins.
  ///
  /// The chip is the only place a *background* tab can be addressed at all: the
  /// workbench shows one tab's regions at a time, so a pane can be dropped onto
  /// a region only while its tab is in front. Dropping on the chip says "into
  /// that tab" and the front region of the tab's focused group is where it
  /// lands — the same place a new pane would.
  String get _paneAnchor =>
      widget.tab.layout.groupOf(widget.tab.focusedPaneId)?.activePaneId ??
      widget.tab.focusedPaneId;

  /// Where [tabId] sits in *this* strip, or -1 when it is in another group's.
  int _indexInStrip(String tabId) {
    final group = widget.groupId;
    final tabs = group == null
        ? ref.read(terminalTabsProvider)
        : ref.read(terminalSessionsControllerProvider.notifier).tabsInGroup(
            group,
          );
    return tabs.indexWhere((tab) => tab.id == tabId);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        TabDrag(:final tabId) => () {
          _updatePosition(details.data, details.offset);
          return tabId != widget.tab.id;
        }(),
        // Which half of the chip the pointer is over means nothing to a pane —
        // a tab is a destination here, not a place in a list — so the position
        // is left alone and the whole chip lights up instead.
        PaneDrag(:final paneId) => sessions.canMovePaneIntoRegion(
          paneId,
          _paneAnchor,
        ),
      },
      onMove: (details) => _updatePosition(details.data, details.offset),
      onLeave: (_) {
        if (mounted) {
          setState(() {
            _ctrlPressed = false;
          });
        }
      },
      onAcceptWithDetails: (details) {
        // The pane keeps its id, its process and its buffer: the controller
        // moves it between the two tabs' layouts and never touches
        // `_instances`, so the terminal is the same object at a new address.
        if (details.data case PaneDrag(:final paneId)) {
          sessions.movePaneIntoRegion(paneId, _paneAnchor);
          return;
        }
        if (details.data case TabDrag(:final tabId)) {
          final ctrl = HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed ||
              _ctrlPressed;
          // Ctrl-drop divides the **workspace** and puts the tab in the new
          // group, not the tab it was dropped on: a tab carries a session, a
          // view and a status strip together, and only a group can host that.
          if (ctrl && tabId != widget.tab.id && widget.groupId != null) {
            sessions.moveTabBesideGroup(
              tabId,
              widget.groupId!,
              SplitAxis.horizontal,
              insertBefore: _dropLeading,
            );
          } else {
            final from = _indexInStrip(tabId);
            if (from >= 0) {
              final insertIndex = _dropLeading
                  ? (from < widget.index ? widget.index - 1 : widget.index)
                  : (from < widget.index ? widget.index : widget.index + 1);
              sessions.reorderTab(tabId, insertIndex);
            } else if (widget.groupId case final group?) {
              // From another group's strip: it moves here, at the edge of this
              // chip the pointer is over.
              sessions.moveTabToGroup(
                tabId,
                group,
                index: _dropLeading ? widget.index : widget.index + 1,
              );
            }
          }
        }
      },
      builder: (context, candidate, _) {
        final incoming = candidate.isEmpty ? null : candidate.first;
        // A pane joins the whole tab, so the whole chip is marked. The caret a
        // tab drop draws would be a lie: there is no position to land at.
        if (incoming is PaneDrag) {
          return _markedForJoin(context, widget.chip, key: kPaneJoinMarker);
        }
        if (incoming is! TabDrag) return widget.chip;

        if (_ctrlPressed) {
          return _markedForJoin(
            context,
            widget.chip,
            key: kTabSplitMarker,
            icon: AppIcons.squareSplitHorizontal,
          );
        }

        return _markedForDrop(
          context,
          widget.chip,
          leading: _dropLeading,
        );
      },
    );
  }
}

/// What a dragged tab looks like under the pointer.
///
/// Deliberately not the chip itself: the chip is as wide as the strip gave it
/// and carries a close button, and dragging a control that can still be clicked
/// reads as a bug. A label is enough to say which tab is in flight.
class _TabDragFeedback extends StatelessWidget {
  const _TabDragFeedback({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 4,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.terminal,
              size: Chrome.icon,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether group [groupId] is showing terminal **panes** right now.
///
/// Two surfaces can be up instead: the conversation, and the empty state a
/// session with no pane of ours gets ([_hostedSelection]). While either is, no
/// terminal tab is on screen in that group — so none of its tabs may draw as
/// the active one, in the strip or in the picker.
///
/// A null [groupId] means the focused group, for the picker, which lists the
/// window's tabs and marks the one the keyboard is in.
bool _showingPanes(WidgetRef ref, {String? groupId}) {
  final group = groupId ?? ref.watch(focusedWorkspaceGroupProvider);
  // Before the window has a workspace there is nothing but the terminal.
  if (group == null) return true;
  if (!ref.watch(terminalVisibleInGroupProvider(group))) return false;
  return _hostedSelection(ref, group) == null;
}

/// Every terminal tab, as [TabPicker] lists them.
///
/// Top-level because two things open that picker on the same list: the strip's
/// overflow button, and quick open's "Switch terminal tab…". Built only while
/// the picker is up, because this is the expensive half — telling two `zsh`
/// tabs apart means knowing which session runs in which pane, and that is a
/// query the strip itself never needs.
List<TabEntry> terminalTabEntries(WidgetRef ref) {
  final terminals = ref.watch(terminalSessionsControllerProvider);
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  // Adopting a pane, or launching into one, rewrites `pane_id` on the row; a
  // rename changes what a tab is called.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.title,
    SessionChangeKind.placement,
  });
  // The panes that exist, not every session ever opened. The pane index makes
  // this proportional to the tabs on screen — the same narrowing
  // `activePaneSessionIdProvider` already made, and for the same reason: this
  // was a full table scan run to label a strip of a dozen tabs.
  final titles = <String, String>{
    for (final record in ref.read(sessionDaoProvider).getByPaneIds([
      for (final tab in terminals.tabs) ...tab.layout.panes,
    ]))
      if (record.paneId != null) record.paneId!: record.title,
  };
  final onPanes = _showingPanes(ref);
  final active = terminals.activeTabId;
  return [
    for (final tab in terminals.tabs)
      TabEntry(
        item: QuickOpenItem(
          id: 'tab/${tab.id}',
          group: QuickOpenGroup.tabs,
          title: sessions.titleForTab(tab.id),
          subtitle: _whereabouts(tab, titles, sessions),
          // A document is not a process, so it has neither a liveness to
          // report nor a shell's glyph — "not running" would be true of a page
          // and would say nothing about it.
          detail:
              _isDocumentTab(tab) || sessions.livenessForTab(tab.id).isLive
              ? null
              : 'not running',
          icon: _isDocumentTab(tab) ? AppIcons.gearSix : AppIcons.terminal,
          onSelect: () => activateTerminalTab(ref, tab.id),
        ),
        active: onPanes && tab.id == active,
        onClose: () => sessions.closeTab(tab.id),
      ),
  ];
}

/// Whether every pane in [tab] is a surface the workbench draws itself — the
/// Settings tab, and nothing else so far.
bool _isDocumentTab(TerminalTab tab) => tab.layout.panes.every(isDocumentPane);

/// Where a tab is: the session running in its focused pane, the directory
/// that pane is in, or both.
///
/// Without it a window full of `zsh` tabs is a list of identical rows, and a
/// picker you cannot pick from is not an answer to anything.
String? _whereabouts(
  TerminalTab tab,
  Map<String, String> sessionTitles,
  TerminalSessionsController sessions,
) {
  final paneId = tab.focusedPaneId;
  final parts = [
    ?sessionTitles[paneId],
    ?sessions.instanceFor(paneId)?.workingDirectory,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
