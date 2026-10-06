import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';

import 'package:agent_cli/descriptors.dart';
import '../../features/automations/presentation/scheduled_resume_chip.dart';
import '../../features/sessions/presentation/queued_messages_strip.dart'
    show QueuedCountChip;
import '../../features/cli_detection/presentation/imported_session_view.dart';
import '../../features/editor/application/editor_tab_actions.dart';
import '../../features/editor/application/open_documents.dart';
import '../../features/editor/presentation/editor_close_guard.dart';
import '../../features/explorer/application/explorer_actions.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/explorer/application/where_you_are.dart';
import '../../features/notes/application/note_drafts.dart';
import '../../features/notes/application/note_tabs.dart';
import '../../features/agents/application/agent_providers.dart';
import '../../features/agents/presentation/agent_logo.dart';
import '../../features/sessions/application/acp_session_providers.dart';
import '../../features/sessions/application/session_agent_providers.dart';
import '../../features/sessions/application/session_location_providers.dart';
import '../../features/sessions/application/delivery_providers.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_status_providers.dart';
import '../../features/sessions/application/host_lifecycle/host_lifecycle_providers.dart'
    show hostLifecycleSubscriberProvider;
import '../../features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import '../../features/sessions/presentation/approval_request_card.dart';
import '../../features/sessions/presentation/session_agent_mark.dart';
import '../../features/sessions/presentation/session_environment_mark.dart';
import '../../features/sessions/presentation/session_notice_line.dart';
import '../../features/sessions/presentation/delivery_strip.dart';
import '../../features/sessions/presentation/model_chip.dart';
import '../../features/sessions/presentation/permission_mode_chip.dart';
import '../../features/sessions/presentation/session_mode_picker.dart';
import '../../features/sessions/presentation/operator_chip.dart';
import '../../features/sessions/presentation/session_stats_dialog.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/terminal/application/browser_document_pane.dart';
import '../../features/terminal/application/terminal_presets.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/terminal/presentation/close_tabs_dialog.dart';
import '../../features/terminal/presentation/empty_pane_region.dart';
import '../../features/terminal/presentation/pane_layout_view.dart';
import '../../features/terminal/presentation/shell_status_line.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';
import 'tab_picker.dart';
import 'workbench_conversation.dart';
import 'workbench_tabs.dart';
import 'workbench_split.dart';
import 'tab_strip_metrics.dart';
import '../widgets/adaptive_modal.dart';
import 'zen_bar.dart' show kZenBarRoom;
import '../../features/sessions/presentation/session_subagents_panel.dart'
    show SessionSubagentsBadge;

// Re-exported so `workbench.dart` stays the one import for the tab strip.
export 'tab_strip_metrics.dart';

// Re-exported: this is the file the strip's callers already import.
export 'workbench_tabs.dart';

// `part`s rather than libraries of their own because privacy in Dart is per
// library: every widget below is private and the tree golden records its name.
import 'session_more_button.dart';
import '../widgets/yielding_row.dart';

part 'workbench_compact.dart';
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

/// The primary content area: one tab strip, the work underneath. A selection
/// shows the session's *terminal* unless the Chat half of [_ViewToggle] says not.
class WorkbenchView extends ConsumerStatefulWidget {
  const WorkbenchView({super.key});

  @override
  ConsumerState<WorkbenchView> createState() => _WorkbenchViewState();
}

class _WorkbenchViewState extends ConsumerState<WorkbenchView> {
  /// The pane the workbench last opened the selected session on, or null. What
  /// [_followSessionPane] compares against, so an unrelated publish is cheap.
  String? _shownPane;

  @override
  void initState() {
    super.initState();
    // Nothing is opened here: an empty workspace offers its New terminal
    // button. Opening one at mount started a new shell on the default
    // profile's machine — an SSH box — at every launch (owner, 2026-10-01).
    // A session can already be selected when the workbench mounts; the listener
    // in `build` only fires on a *change*, so the mount catches up by hand.
    final selected = ref.read(selectedSessionIdProvider);
    final active = ref.read(activePaneSessionIdProvider);
    if (selected == null && active == null) return;
    if (selected != null) _shownPane = sessionTerminalPane(ref, selected);
    // Riverpod forbids writing a provider from `initState`, and reattaching a
    // pane there would republish the terminal while the tree is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A restored layout can put an agent pane on screen before anything is
      // selected; the context panel should describe that session.
      if (active != null) ref.read(sessionContextProvider).follow(active);
      if (selected != null) _openSession(selected);
      _hostSelection();
    });
  }

  /// Records the group the sidebar's selection was opened into. Only ever
  /// *recorded* — see [selectionHostGroupProvider].
  void _hostSelection() {
    final selected =
        ref.read(selectedSessionIdProvider) ??
        ref.read(selectedImportedSessionIdProvider);
    ref
        .read(selectionHostGroupProvider.notifier)
        .host(
          selected == null ? null : ref.read(focusedWorkspaceGroupProvider),
        );
  }

  /// Reveals the pane [sessionId] is already running in; starts and stops
  /// nothing. [sessionId] names the change so it wakes only that row's watchers.
  void _showTerminalFor(String? paneId, String? sessionId) =>
      showTerminalFor(ref, paneId, sessionId);

  /// Opens [sessionId] on the surface a session *is*: its terminal. No branch on
  /// whether it has a pane — one that has none gets [_NoPaneForSession] — except
  /// a session with no terminal to have: its conversation becomes the tab.
  void _openSession(String sessionId) {
    var paneId = sessionTerminalPane(ref, sessionId);
    if (paneId == null && ref.read(isAcpSessionProvider(sessionId))) {
      ref
          .read(terminalSessionsControllerProvider.notifier)
          .openChatTab(sessionId);
      paneId = chatPaneId(sessionId);
    }
    _showSurfaceFor(paneId, sessionId);
  }

  /// Follows the selected session onto the pane it acquires, or loses: the
  /// Explorer selects a row *before* it resumes it, so the pane arrives late.
  void _followSessionPane() {
    final sessionId = ref.read(selectedSessionIdProvider);
    if (sessionId == null) return;
    final paneId = sessionTerminalPane(ref, sessionId);
    if (paneId == _shownPane) return;
    // A thread on its chat tab keeps it: a terminal arriving behind it — a
    // resume, a switch to a terminal agent — is secondary (owner, 2026-10-03).
    final chat = chatPaneId(sessionId);
    if (_shownPane == chat &&
        paneId != null &&
        ref.read(paneSessionsProvider).sessionOf(chat) == sessionId) {
      return;
    }
    // A session that *had* a pane and no longer has one has been ended, which
    // is a different act from selecting one that never had a pane.
    final ended = _shownPane != null && paneId == null;
    _shownPane = paneId;
    // Gaining a pane moves the workbench onto it, or the session would be off
    // screen.
    if (paneId != null) {
      _showTerminalFor(paneId, sessionId);
      _showChatOnCompact(paneId);
    } else if (ended) {
      _releaseEndedPane();
    }
  }

  /// Lets go of the selected session once its pane is gone: ending one must not
  /// park the user on [_NoPaneForSession] while live tabs sit behind it.
  void _releaseEndedPane() {
    if (!ref.read(terminalVisibleProvider)) return;
    ref.read(selectedSessionIdProvider.notifier).select(null);
  }

  void _showSurfaceFor(String? paneId, String? sessionId) {
    _shownPane = paneId;
    _showTerminalFor(paneId, sessionId);
    _showChatOnCompact(paneId);
  }

  /// On a phone a session opens on its chat (Stage 2 answer 3). The pane is
  /// still reattached above, so the terminal is one tap away.
  void _showChatOnCompact(String? paneId) {
    if (!CompactWorkbenchScope.of(context)) return;
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    if (paneId != null) {
      terminals.revealConversationForPane(paneId);
    } else if (ref.read(focusedWorkspaceGroupProvider) case final group?) {
      terminals.showFaceIn(group, terminal: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Picking a session in the sidebar is a request to work *in* it. A listener
    // rather than a build-time branch, so a switch to the conversation sticks.
    ref.listen(selectedSessionIdProvider, (_, next) {
      if (next != null) _openSession(next);
      // After the open, so the group recorded is the one the session landed
      // in rather than the one the keyboard was in a moment earlier.
      _hostSelection();
    });
    ref.listen(selectedImportedSessionIdProvider, (_, next) {
      // An imported CLI session has no pane of ours *yet*; the tap that selected
      // it is already resuming it into one (`openImported`).
      if (next != null) _showSurfaceFor(null, null);
      _hostSelection();
    });
    // The pane the selected session has can arrive after the tap that selected
    // it, or go away under it. See [_followSessionPane].
    ref.listen(terminalSessionsControllerProvider, (_, _) {
      _followSessionPane();
    });
    // And off what that is derived into: heard on the controller alone, a
    // listener registered before [paneSessionsProvider]'s own can read the
    // pane a closed tab held. A rebuild after the first frame used to hide it.
    ref.listen(paneSessionsProvider, (_, _) => _followSessionPane());
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
    // The context panel describes the session you are in — driven by the pane
    // on screen, not the selection, so activating another tab moves it too.
    ref.listen(activePaneSessionIdProvider, (_, next) {
      final context = ref.read(sessionContextProvider);
      // A shell tab follows no *session*, and saying so matters: a checkout
      // picked while one is up would otherwise stick to the last followed
      // session. Where it is working is a separate question, below.
      next == null ? context.stopFollowing() : context.follow(next);
    });
    // On a phone a document brought up (a file from the chat or the context
    // sheet) wins over a selected session with no pane, as a tab picked does.
    ref.listen(
      terminalSessionsControllerProvider.select(
        (s) => (s.activeTab?.id, s.activeTab?.focusedPaneId),
      ),
      (was, now) {
        final (tabId, paneId) = now;
        if (was == now || tabId == null || paneId == null) return;
        if (!isDocumentPane(paneId) || !CompactWorkbenchScope.of(context)) {
          return;
        }
        final terminals = ref.read(terminalSessionsControllerProvider.notifier);
        releaseHijackedSelection(ref, inGroup: terminals.groupOfTab(tabId));
      },
    );
    // Going somewhere yourself releases whatever your last click was holding.
    ref.listen(
      terminalSessionsControllerProvider.select(
        (s) => s.activeTab?.focusedPaneId,
      ),
      (_, _) => ref.read(explorerFollowHoldProvider.notifier).release(),
    );
    // **Where the pane on screen is working, now** — an agent's hook cwd, a
    // shell's OSC 7, or the directory the session was launched in. A click in
    // the sidebar outranks it until you move panes.
    ref.listen(focusedDirectoryProvider, (_, next) {
      if (next == null) return;
      if (ref.read(explorerFollowHoldProvider)) return;
      ref.read(sessionContextProvider).followDirectory(next);
    });

    final workspace = ref.watch(workspaceLayoutProvider);
    // Before the first tab there is no tree at all, and one group stands in for
    // it: an empty strip, and no session to put a bar under.
    if (workspace == null) {
      return const _WorkspaceGroup(groupId: null);
    }
    // A phone has room for one group: the focused one, with the others kept
    // mounted behind it so their state is there when the window widens.
    if (CompactWorkbenchScope.of(context)) {
      final focused = ref.watch(focusedWorkspaceGroupProvider);
      final groups = workspace.groups;
      final index = groups.indexWhere((group) => group.id == focused);
      return IndexedStack(
        index: index < 0 ? 0 : index,
        sizing: StackFit.expand,
        children: [
          for (final group in groups)
            _WorkspaceGroup(key: ValueKey(group.id), groupId: group.id),
        ],
      );
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
      ),
    );
  }
}

/// Reveals the pane [sessionId] is already running in; starts and stops nothing.
/// [sessionId] names the change, so only that row's watchers wake.
void showTerminalFor(WidgetRef ref, String? paneId, String? sessionId) {
  if (paneId != null) {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    terminals
      ..reattachSession(paneId)
      ..focusPane(paneId);
    // Which pane this session shows in moved, and nothing about any other row.
    ref.publishSessionChange(
      sessionId == null
          ? const SessionChange(kinds: {SessionChangeKind.placement})
          : SessionChange.moved(sessionId),
    );
  }
  // The group that pane is in — not the focused one. A launch or a reveal means
  // "show me it *there*", and with two groups those are different answers.
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  paneId == null
      ? terminals.showTerminalHere()
      : terminals.showTerminalForPane(paneId);
}
