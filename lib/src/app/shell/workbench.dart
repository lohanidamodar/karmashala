import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/detail/presentation/workbench_session_view.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/sessions/presentation/agent_status_badge.dart';
import '../../features/sessions/presentation/approval_request_card.dart';
import '../../features/sessions/presentation/delivery_strip.dart';
import '../../features/sessions/presentation/permission_mode_chip.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';

/// The primary content area: one tab strip across the top, the work underneath.
///
/// Loop 47 moved the terminal here from a 280px bottom dock. A dock is right for
/// an *editor*-primary app; Chitragupta decided to be terminal-primary, and none
/// of the products it is learning from (Orca, cmux, Warp, Ghostty) put the
/// terminal anywhere but the middle of the window.
///
/// **One session, two views.** A session that runs in one of our panes is not
/// two things. Its chat rendering and its terminal are two surfaces of the same
/// record, switched by the toggle at the right of the strip — which is why the
/// switch reattaches and focuses rather than starting anything. Which surface is
/// showing is [terminalVisibleProvider]: `true` is the terminal, `false` is the
/// conversation. Nothing else needed a new provider.
///
/// **The terminal is the one you land on.** Until Loop 85 selecting a session
/// switched the workbench to its *chat*, which made the secondary view the
/// default one and left every session action (handoff, fork, the delivery
/// lifecycle, an approval that is blocking the agent) reachable only from
/// there. Now a selection opens the session's pane, and those controls are
/// composed around it from the same widgets the conversation uses — see
/// [_TerminalSurface]. Chat is one labelled tap, or `` Ctrl+` ``, away.
class WorkbenchView extends ConsumerStatefulWidget {
  const WorkbenchView({super.key});

  @override
  ConsumerState<WorkbenchView> createState() => _WorkbenchViewState();
}

class _WorkbenchViewState extends ConsumerState<WorkbenchView> {
  @override
  void initState() {
    super.initState();
    // A session can already be selected when the workbench mounts — the shell
    // rebuilding around it, or a selection made by something that ran first.
    // The listener in `build` only fires on a *change*, so without this the
    // one case the whole loop is about would be the case that lands on chat.
    final selected = ref.read(selectedSessionIdProvider);
    if (selected == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openSession(selected);
    });
  }

  void _showChat() => ref.read(terminalVisibleProvider.notifier).set(false);

  /// Reveals the pane the selected session is already running in. Starts and
  /// stops nothing: a detached pane comes back as a tab, one already in a tab is
  /// simply focused.
  void _showTerminalFor(String? paneId) {
    if (paneId != null) {
      final terminals = ref.read(terminalSessionsControllerProvider.notifier);
      terminals
        ..reattachSession(paneId)
        ..focusPane(paneId);
      ref.read(sessionsRevisionProvider.notifier).bump();
    }
    ref.read(terminalVisibleProvider.notifier).set(true);
  }

  /// Opens [sessionId] on the surface a session *is*: its terminal.
  ///
  /// Falls back to the conversation only when there is genuinely no pane to
  /// show — an imported CLI session, one opened in an external terminal, or one
  /// whose pane the user has ended. Landing on an empty terminal, or on some
  /// other session's tab, would be worse than the secondary view.
  void _openSession(String sessionId) {
    // `sessionTerminalPane` is the one answer to "has it got a terminal", and
    // the conversation's empty state reads it too, so the fallback and what the
    // fallback then says cannot contradict each other.
    final paneId = sessionTerminalPane(ref, sessionId);
    if (paneId == null) {
      _showChat();
    } else {
      _showTerminalFor(paneId);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Picking a session in the Explorer is a request to *work in* it, and the
    // session is its terminal. Kept as a listener rather than a build-time
    // branch so the user can switch to the conversation and stay there.
    ref.listen(selectedSessionIdProvider, (_, next) {
      if (next != null) _openSession(next);
    });
    ref.listen(selectedImportedSessionIdProvider, (_, next) {
      // An imported CLI session has no pane of ours; the transcript we read out
      // of the CLI's own store is the only surface it has.
      if (next != null) _showChat();
    });

    final scheme = Theme.of(context).colorScheme;
    final session = _selectedSession();
    final terminals = ref.watch(terminalSessionsControllerProvider);
    // With nothing to read, the workbench is the terminal — an empty middle
    // would be worse than the surface the app is primarily about.
    final onTerminal = ref.watch(terminalVisibleProvider) || session == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
          session: session,
          onTerminal: onTerminal,
          terminals: terminals,
          onShowSession: _showChat,
          onShowTerminal: _showTerminalFor,
        ),
        const Divider(height: 1),
        Expanded(
          child: ColoredBox(
            color: scheme.surfaceContainerLowest,
            // With two surfaces, an IndexedStack rather than a branch: the
            // conversation keeps its scroll position while the terminal is up,
            // and — the Loop 26 property — the hidden one paints nothing. With
            // one surface there is nothing to keep alive, so it is not paid for.
            child: session == null
                ? const _TerminalSurface()
                : IndexedStack(
                    index: onTerminal ? 0 : 1,
                    children: const [
                      _TerminalSurface(),
                      WorkbenchSessionView(),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// The session the Explorer has selected, if any, as the workbench needs it:
  /// a title, whether it has a pane of ours, and whether it is one of ours at
  /// all (imported CLI sessions have no pane and no live status).
  _WorkbenchSession? _selectedSession() {
    ref.watch(sessionsRevisionProvider);
    final importedId = ref.watch(selectedImportedSessionIdProvider);
    if (importedId != null) {
      final imported = ref.read(importedSessionDaoProvider).getById(importedId);
      return _WorkbenchSession(
        id: importedId,
        title: imported?.displayTitle ?? 'Session',
        paneId: null,
        native: false,
      );
    }
    final sessionId = ref.watch(selectedSessionIdProvider);
    if (sessionId == null) return null;
    final Session? record = ref.read(sessionDaoProvider).getById(sessionId);
    return _WorkbenchSession(
      id: sessionId,
      title: record?.title ?? 'Session',
      paneId: sessionTerminalPane(ref, sessionId),
      native: true,
    );
  }
}

class _WorkbenchSession {
  const _WorkbenchSession({
    required this.id,
    required this.title,
    required this.paneId,
    required this.native,
  });

  final String id;
  final String title;

  /// The pane this session can be *shown* in — it runs in one of ours and that
  /// pane is still there. Null for an imported CLI session, one opened in an
  /// external terminal, and one whose pane has been ended: those have a
  /// conversation to read but no terminal of ours to switch to.
  final String? paneId;
  final bool native;
}

/// The terminal rendering of a session: the panes, and the controls that belong
/// to whichever session is running in the pane on screen.
///
/// The controls are the chat view's own widgets, not lookalikes — one
/// [ApprovalRequestCard] and one [DeliveryStrip] exist in the app, so the two
/// views cannot offer different answers or different next steps. They sit
/// *below* the panes because that is where the thing they respond to is: an
/// agent's prompt is drawn at the bottom of its terminal, so the buttons that
/// answer it are the next thing under it rather than a header the eye has to
/// travel back up to.
class _TerminalSurface extends StatelessWidget {
  const _TerminalSurface();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: TerminalPaneStack()),
        _PaneSessionDock(),
      ],
    );
  }
}

/// The session controls under the terminal, for the focused pane's session.
///
/// Every part of it is conditional and each decides for itself, using the rule
/// it already had: the approval card draws nothing unless that session is
/// blocked on a prompt, and the delivery strip nothing unless it has a stage,
/// an action or a handoff to offer. A shell tab has no session at all and gets
/// no dock. Nothing here reserves height for something it might later say.
class _PaneSessionDock extends ConsumerWidget {
  const _PaneSessionDock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminals = ref.watch(terminalSessionsControllerProvider);
    final sessionId = _focusedPaneSessionId(ref, terminals);
    if (sessionId == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the delivery row for the same reason it is above it in the
        // conversation: it is the thing blocking the session, and nothing else
        // offered here will be read until the agent's prompt is answered.
        ApprovalRequestCard(sessionId: sessionId, hostedOnTerminal: true),
        DeliveryStrip(sessionId: sessionId),
      ],
    );
  }
}

/// The session running in the pane the terminal view is showing, if any.
///
/// Keyed off the *pane on screen*, not off the Explorer's selection: switching
/// terminal tabs changes which agent you are looking at, and controls that
/// followed the tree selection would act on a different session than the one
/// under them. A shell tab has no session row pointing at it and answers null.
String? _focusedPaneSessionId(WidgetRef ref, TerminalSessionsState terminals) {
  final paneId = terminals.activeTab?.focusedPaneId;
  if (paneId == null) return null;
  // Adopting a pane, or launching into one, rewrites `paneId` on the row.
  ref.watch(sessionsRevisionProvider);
  for (final record in ref.read(sessionDaoProvider).getAll()) {
    if (record.paneId == paneId) return record.id;
  }
  return null;
}

class _TabStrip extends ConsumerWidget {
  const _TabStrip({
    required this.session,
    required this.onTerminal,
    required this.terminals,
    required this.onShowSession,
    required this.onShowTerminal,
  });

  final _WorkbenchSession? session;
  final bool onTerminal;
  final TerminalSessionsState terminals;
  final VoidCallback onShowSession;
  final ValueChanged<String?> onShowTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final active = terminals.activeTabId;

    return Container(
      height: Chrome.tabStrip,
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                if (session != null)
                  WorkbenchTabChip(
                    selected: !onTerminal,
                    onTap: onShowSession,
                    label: session!.title,
                    tooltip: 'Conversation · ${session!.title}',
                    leading: Padding(
                      padding: const EdgeInsets.only(right: Insets.sm),
                      child: session!.native
                          ? AgentStatusBadge(sessionId: session!.id)
                          : const Icon(
                              AppIcons.clockCounterClockwise,
                              size: Chrome.iconSmall,
                            ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Close conversation',
                      iconSize: 13,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(AppIcons.x),
                      onPressed: () {
                        ref
                            .read(selectedSessionIdProvider.notifier)
                            .select(null);
                        ref
                            .read(selectedImportedSessionIdProvider.notifier)
                            .select(null);
                      },
                    ),
                  ),
                for (final tab in terminals.tabs)
                  TerminalTabChip(
                    title: sessions.titleForTab(tab.id),
                    liveness: sessions.livenessForTab(tab.id),
                    selected: onTerminal && tab.id == active,
                    onTap: () {
                      sessions.activateTab(tab.id);
                      onShowTerminal(null);
                    },
                    onClose: () => sessions.closeTab(tab.id),
                    onEnd: () => sessions.closeTab(tab.id, detach: false),
                  ),
              ],
            ),
          ),
          // The permission mode belongs to the session, not to one of its two
          // renderings. It was on the chat composer only, so the same control
          // was readable on one view and invisible on the other; this is the
          // same widget reading the same `effectivePermissionFor`, so the two
          // views cannot disagree.
          if (onTerminal) _PanePermissionChip(terminals: terminals),
          if (session?.paneId != null)
            _ViewToggle(
              onTerminal: onTerminal,
              onChat: onShowSession,
              onTerminalView: () => onShowTerminal(session!.paneId),
            ),
          const TerminalToolbar(),
          const _ZenButton(),
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }
}

/// The permission chip for the agent pane the terminal view is showing.
///
/// Follows the focused pane rather than the tree, for the reason given on
/// [_focusedPaneSessionId]. A shell tab draws nothing.
class _PanePermissionChip extends ConsumerWidget {
  const _PanePermissionChip({required this.terminals});

  final TerminalSessionsState terminals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = _focusedPaneSessionId(ref, terminals);
    if (sessionId == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: Insets.sm),
      child: PermissionModeChip(sessionId: sessionId),
    );
  }
}

/// The two renderings of one session. Not a navigation control: both sides show
/// the same record, the same PTY and the same lifecycle.
///
/// Labelled in words as well as icons. The terminal is where a session opens
/// now, so the way back to its conversation cannot be a chord and a hover — it
/// has to be a thing on the strip that says what it is.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.onTerminal,
    required this.onChat,
    required this.onTerminalView,
  });

  final bool onTerminal;
  final VoidCallback onChat;
  final VoidCallback onTerminalView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget half(
      IconData icon,
      String label,
      String tip,
      bool selected,
      VoidCallback onTap,
    ) {
      final colour = selected ? scheme.primary : scheme.onSurfaceVariant;
      return Tooltip(
        message: tip,
        child: Semantics(
          button: true,
          selected: selected,
          label: tip,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: Chrome.iconSmall, color: colour),
                  const SizedBox(width: Insets.xs),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(color: colour),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              half(
                AppIcons.terminal,
                'Terminal',
                'Terminal view',
                onTerminal,
                onTerminalView,
              ),
              half(
                AppIcons.chatCircle,
                'Chat',
                'Chat view',
                !onTerminal,
                onChat,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hides the Explorer and the side panel so the workbench has the window.
class _ZenButton extends ConsumerWidget {
  const _ZenButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zen = ref.watch(terminalMaximizedProvider);
    return IconButton(
      tooltip: zen ? 'Show the panels (Ctrl+\\)' : 'Focus mode (Ctrl+\\)',
      isSelected: zen,
      icon: const Icon(AppIcons.arrowsOutSimple, size: Chrome.icon),
      onPressed: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
    );
  }
}
