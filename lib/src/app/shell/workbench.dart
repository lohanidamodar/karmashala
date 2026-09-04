import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/agents/domain/agent_status.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/detail/presentation/workbench_session_view.dart';
import '../../features/explorer/application/explorer_actions.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_status_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/sessions/presentation/session_notice_line.dart';
import '../../features/sessions/presentation/delivery_strip.dart';
import '../../features/sessions/presentation/model_chip.dart';
import '../../features/sessions/presentation/permission_mode_chip.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/domain/pane_liveness.dart';
import '../../features/terminal/domain/terminal_drag.dart';
import '../../features/terminal/presentation/close_tabs_dialog.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';
import 'tab_picker.dart';
import 'tab_strip_metrics.dart';

// The strip's uniform-extent rule lives beside the strip's other consumers —
// a region header shares it. Re-exported so `workbench.dart` is still the one
// import anything about the tab strip needs.
export 'tab_strip_metrics.dart';

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
/// still has. See [_releaseEndedPane], and [_releaseHijackedSelection] for the
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

  /// The session whose **conversation** is mounted, or null when none is.
  ///
  /// The conversation is built only once it has been asked for, and only for
  /// the session it was asked for. An [IndexedStack] builds every child, so
  /// putting the two surfaces in one meant that landing on a session's terminal
  /// — which is what every tap does — also mounted its chat view, and
  /// `sessionChatTranscriptProvider` answers a fresh subscription with a CLI
  /// **store scan** followed by a read and JSON parse of that session's
  /// **whole transcript file**. Two sessions switched back and forth paid that
  /// on every switch, for a surface nobody was looking at: the lag the owner
  /// reported. Measured in `session_switch_cost_test.dart`.
  ///
  /// What the stack was for survives: while the conversation *is* the surface
  /// the user chose, both children stay built, so toggling to the terminal and
  /// back keeps its scroll position. Only the never-asked-for case is dropped —
  /// and a switch to another session is exactly that case, because a different
  /// session's transcript has no scroll position to keep.
  ///
  /// **Mounted is not the same as working**, and the difference is the second
  /// half of this design. A conversation kept alive behind the terminal went on
  /// polling: `sessionChatTranscriptProvider` re-reads and JSON-decodes that
  /// session's *whole* transcript every two seconds whenever the file has moved
  /// — 43.8 MB over 11 637 lines on the owner's machine, 888 ms a tick, moving
  /// constantly, because the agent writing it is the one being typed to. So
  /// the poll is gated on which
  /// surface is in front (`chatTranscriptPollingProvider`, keyed off
  /// [terminalVisibleProvider]): the view keeps its scroll position and its
  /// place in the tree, and stops doing megabytes of work on the UI isolate
  /// under every keystroke. Measured in
  /// `test/app/shell/keystroke_cost_test.dart`.
  String? _conversationFor;

  @override
  void initState() {
    super.initState();
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
    });
  }

  /// **The only write of `false` in the app.** Wired to the labelled Chat half
  /// of the bar's toggle and to nothing else, which is what makes "a tap never
  /// opens the conversation" a property rather than a race won.
  void _showChat() => ref.read(terminalVisibleProvider.notifier).set(false);

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
  void _showTerminalFor(String? paneId, String? sessionId) {
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
    ref.read(terminalVisibleProvider.notifier).set(true);
  }

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
  /// **Cleared, not out-voted**, for the reason [_releaseHijackedSelection]
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
    });
    ref.listen(selectedImportedSessionIdProvider, (_, next) {
      // An imported CLI session has no pane of ours *yet* — the tap that
      // selected it is already resuming it into one (`openImported`). This used
      // to switch straight to the transcript, which is how the one path the
      // user could not miss opened the chat interface every single time.
      if (next != null) _showSurfaceFor(null, null);
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

    final scheme = Theme.of(context).colorScheme;
    final session = _selectedSession();
    // With nothing to read, the workbench is the terminal — an empty middle
    // would be worse than the surface the app is primarily about.
    final onTerminal = ref.watch(terminalVisibleProvider) || session == null;
    // Asked for, or let go of — see [_conversationFor]. Written here rather
    // than in a listener because both inputs are read here and nowhere else,
    // and neither is a provider this may write to.
    if (!onTerminal) {
      _conversationFor = session.id;
    } else if (_conversationFor != session?.id) {
      _conversationFor = null;
    }
    final conversationMounted = session != null && _conversationFor != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _TabStrip(),
        const Divider(height: 1),
        Expanded(
          child: ColoredBox(
            color: scheme.surfaceContainerLowest,
            // With two surfaces up, an IndexedStack rather than a branch: the
            // conversation keeps its scroll position while the terminal is up,
            // and — the Loop 26 property — the hidden one paints nothing. With
            // one surface there is nothing to keep alive, so it is not paid
            // for — and until the conversation has been asked for there is no
            // second surface at all ([_conversationFor]).
            child: session == null
                ? const _TerminalSurface()
                : IndexedStack(
                    key: kWorkbenchSurfaces,
                    index: onTerminal ? 0 : 1,
                    children: [
                      _TerminalSurface(session: session),
                      // [WorkbenchSessionView] renders whatever the Explorer
                      // has selected, which is right until nothing is: a
                      // session the workbench reached by following the pane
                      // would find that view's "open a session" placeholder
                      // behind the toggle. It is named outright in that case.
                      // Only a native session is ever reached that way — an
                      // imported one has no pane of ours to follow.
                      if (conversationMounted)
                        if (session.selected)
                          const WorkbenchSessionView()
                        else
                          SessionTranscriptView(sessionId: session.id),
                    ],
                  ),
          ),
        ),
        // Outside the stack, because the toggle is the way *back* from the
        // conversation as well as the way to it: hosted on the terminal surface
        // it would be built and unreachable for exactly the surface that has no
        // other way home.
        _SessionBar(
          session: session,
          onTerminal: onTerminal,
          onChat: _showChat,
          onTerminalView: () => _showTerminalFor(session?.paneId, session?.id),
        ),
      ],
    );
  }

  /// The session the workbench is about, if any, as it needs it: a title,
  /// whether it has a pane of ours, and whether it is one of ours at all
  /// (imported CLI sessions have no pane and no live status).
  ///
  /// **The Explorer's selection, and failing that the pane on screen.** The
  /// rest of the bar already follows the pane — the permission chip, the
  /// delivery strip — so an agent reached by activating its
  /// terminal tab had every session control except the one thing only this
  /// answers: the toggle, and therefore the way to its transcript.
  ///
  /// The fallback is deliberately a **read**, not a selection. Writing
  /// `selectedSessionIdProvider` to make the toggle appear would fire the
  /// listener in [build] that opens the session's terminal, so the way to the
  /// conversation would fight the surface the user is already on. Nothing here
  /// writes anything.
  _WorkbenchSession? _selectedSession() {
    // The strip draws the selected session's name and offers the toggle its
    // pane decides. Statuses and permission modes are drawn elsewhere.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.title,
      SessionChangeKind.placement,
    });
    // A pane appearing or ending changes whether this session has a terminal at
    // all, which is what decides whether the strip offers the toggle. Watched
    // rather than read so the strip cannot keep offering a surface that is
    // gone — but only the tab list, because a *process* dying somewhere else
    // cannot change which panes exist, and at a hundred panes that was the
    // common case.
    ref.watch(terminalSessionsControllerProvider.select((s) => s.tabs));
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
    final selected = ref.watch(selectedSessionIdProvider);
    final sessionId = selected ?? ref.watch(activePaneSessionIdProvider);
    if (sessionId == null) return null;
    final Session? record = ref.read(sessionDaoProvider).getById(sessionId);
    return _WorkbenchSession(
      id: sessionId,
      title: record?.title ?? 'Session',
      paneId: sessionTerminalPane(ref, sessionId),
      native: true,
      selected: selected != null,
    );
  }
}

class _WorkbenchSession {
  const _WorkbenchSession({
    required this.id,
    required this.title,
    required this.paneId,
    required this.native,
    this.selected = true,
  });

  final String id;
  final String title;

  /// Whether the Explorer picked this session, rather than the workbench
  /// having followed the pane on screen to it. What decides which widget draws
  /// the conversation — see the [IndexedStack] in `build`.
  final bool selected;

  /// The pane this session can be *shown* in — it runs in one of ours and that
  /// pane is still there. Null for an imported CLI session, one opened in an
  /// external terminal, and one whose pane has been ended: those have a
  /// conversation to read but no terminal of ours to switch to.
  final String? paneId;
  final bool native;
}

/// The terminal rendering of a session: the panes, and nothing over them.
///
/// No approval card. The agent draws its own prompt here and it is answered by
/// typing into it, so a card repeating the question under the pane duplicated a
/// control the terminal already has; the approval card belongs to the
/// conversation, which has no other way to see that prompt. Everything else
/// that belongs to the session is one row further down, in [_SessionBar].
///
/// With a session selected that has **no pane of ours**, the panes are not what
/// this surface should show — the tab on screen would be some other session's.
/// [_NoPaneForSession] takes their place and says so.
class _TerminalSurface extends StatelessWidget {
  const _TerminalSurface({this.session});

  final _WorkbenchSession? session;

  @override
  Widget build(BuildContext context) {
    final selected = session;
    if (selected != null && selected.paneId == null) {
      return _NoPaneForSession(session: selected);
    }
    return const TerminalPaneStack();
  }
}

/// What the terminal surface shows for a session nothing of ours is running.
///
/// This is what lets "a tap always lands on the terminal" be honest rather than
/// a lie told by showing an unrelated tab. Every sentence is read off
/// `sessionTerminalPane` and the row itself, which is the same pair the
/// conversation's empty hint reads, so the two surfaces cannot describe one
/// session differently.
///
/// It answers a session the user has **asked to see**. It is deliberately not
/// what ending a session leaves behind: that selection is released before this
/// is ever reached ([_releaseEndedPane]), because explaining the corpse of the
/// thing someone just finished with is not an answer to anything.
class _NoPaneForSession extends ConsumerWidget {
  const _NoPaneForSession({required this.session});

  final _WorkbenchSession session;

  /// Whether resuming is something we could actually do. A native row needs the
  /// CLI's own id — without it a "resume" would start a *new* conversation
  /// wearing this row's title, which is the one thing the Explorer refuses to
  /// do (see `ExplorerActions.openNative`). An imported row is nothing but that
  /// id, so it always can.
  bool _canResume(WidgetRef ref) {
    if (!session.native) return true;
    final id = ref
        .read(sessionDaoProvider)
        .getById(session.id)
        ?.externalSessionId;
    return id != null && id.isNotEmpty;
  }

  Future<void> _resume(WidgetRef ref) async {
    final actions = ref.read(explorerActionsProvider);
    final result = session.native
        ? await actions.openNative(session.id)
        : await () async {
            final record = ref
                .read(importedSessionDaoProvider)
                .getById(session.id);
            return record == null
                ? const ExplorerResult(ExplorerOutcome.selected)
                : await actions.openImported(record);
          }();
    final message = result.message;
    if (message == null || !ref.context.mounted) return;
    ScaffoldMessenger.of(
      ref.context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canResume = _canResume(ref);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.terminal,
                size: Chrome.iconHero,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: Insets.md),
              Text(
                session.title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                canResume
                    ? 'No terminal of ours is running this session. Resume it '
                          'to pick the conversation up in one.'
                    : 'No terminal of ours is running this session, and we '
                          'never learned the conversation\'s own id — so it '
                          'cannot be resumed from here. "Copy resume command" '
                          'in the session menu is the way back into it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Insets.md),
              Wrap(
                spacing: Insets.sm,
                alignment: WrapAlignment.center,
                children: [
                  if (canResume)
                    FilledButton.tonalIcon(
                      onPressed: () => _resume(ref),
                      icon: const Icon(AppIcons.playCircle),
                      label: const Text('Resume in a terminal'),
                    ),
                  TextButton(
                    onPressed: () =>
                        ref.read(terminalVisibleProvider.notifier).set(false),
                    child: const Text('Read the conversation'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The chrome under the surface: what belongs to the session on screen, on a
/// bar of its own.
///
/// The controls used to be split between the two ends of the window — the
/// permission chip up in the tab strip, the delivery actions loose under the
/// terminal on no surface at all. One rule instead: the strip is tabs, and this
/// is the session. It is built like the strip (the same rule, the same
/// [Chrome.tabStrip] floor, the same [ColorScheme.surfaceContainerLow]) so the
/// two read as the same kind of thing at either end of the work.
///
/// **What it speaks for is what is on screen.** That is the focused pane's
/// session — [activePaneSessionIdProvider], for the reason given there — not
/// the Explorer's selection, or switching terminal tabs would leave these
/// controls acting on a session the user is no longer looking at. The one
/// exception is [_NoPaneForSession]: no pane is on screen there at all, so the
/// session the bar is about is the selected one, which is also what keeps the
/// toggle — the only way to that session's transcript — from disappearing on
/// exactly the surface that offers nothing else.
///
/// While the conversation is up its composer already carries the permission
/// chip and the delivery strip, so the bar is down to the toggle rather than a
/// second copy of them.
///
/// **Two lines, not one flow.** A quiet [DeliveryStateLine] carrying what is
/// true — the stage, the branch, the counts — over one action row carrying what
/// can be done about it, with the permission control at its left end and the
/// view toggle at its right. Everything used to be poured into a single [Wrap],
/// which sorted itself by whatever fitted: the facts and the buttons ran
/// together at the same weight, `Commit` ended up stranded beside the branch
/// name a row above its three siblings, and the toggle — centred against a
/// two-row block — lined up with nothing. Grouping is the fix, and it is a
/// layout rather than a rule: facts cannot interleave with actions because they
/// are no longer in the same run.
///
/// The row is aligned to its **start** so that the two ends keep the action
/// row's own line when the actions wrap on a narrow window, instead of drifting
/// to the middle of a two-run block. Every control on the row is the same
/// height by construction (`kBarControlPad`), so aligning to the start and
/// aligning to the centre are the same thing while there is one run.
class _SessionBar extends ConsumerWidget {
  const _SessionBar({
    required this.session,
    required this.onTerminal,
    required this.onChat,
    required this.onTerminalView,
  });

  final _WorkbenchSession? session;
  final bool onTerminal;
  final VoidCallback onChat;
  final VoidCallback onTerminalView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = session;
    final sessionId = !onTerminal
        ? null
        : selected != null && selected.paneId == null
        ? selected.id
        : ref.watch(activePaneSessionIdProvider);
    // A shell tab with nothing selected has neither a session to describe nor a
    // surface to switch to, and an empty bar would be 30 pixels of nothing.
    if (sessionId == null && selected == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Container(
          constraints: const BoxConstraints(minHeight: Chrome.tabStrip),
          color: scheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Full width and above everything, so the facts read as a caption
              // over the row rather than as the first item in it.
              if (sessionId != null) ...[
                DeliveryStateLine(sessionId: sessionId),
                // Whatever this session has just been told, in this session's
                // bar. Full width for the same reason, and directly over the
                // chips that post it.
                SessionNoticeLine(sessionId: sessionId),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  // Whether a third control fits beside the permission mode and
                  // the delivery actions. Measured rather than guessed: at
                  // 720px — the smallest window the app supports — the row is
                  // already 14px over with the model chip squeezed to its
                  // glyphs, and 23px over at the 1.3x text step. Scaled by the
                  // text step for the same reason: the two fixed controls grow
                  // with it and the room does not.
                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                  final roomForModel = constraints.maxWidth > 820 * scale;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (sessionId == null)
                        const Spacer()
                      else ...[
                        PermissionModeChip(sessionId: sessionId),
                        const SizedBox(width: Insets.xs),
                        // Beside the permission chip because they are the same kind
                        // of fact: what *this* session runs under, changed from
                        // where the session is. It used to live in the window's
                        // status bar next to the account quota, which put a
                        // per-session control among window-wide ones and left it
                        // describing whichever session the app thought was focused.
                        // Flexible, and the only control here that is. The
                        // delivery actions do not shrink — they wrap to a second
                        // run, which is what put `Commit` a row above its own peers
                        // — and the permission mode is a fixed vocabulary. A model
                        // name is neither: it is the one label here whose width
                        // nobody can predict, so it is the one that gives way. One
                        // part against the strip's eight leaves it the ~118px it
                        // wants at the fullest bar without letting it push the
                        // actions onto a second run.
                        //
                        // Absent rather than crushed below that: the chat surface
                        // carries the same chip at full width, so a narrow terminal
                        // loses a shortcut, not the control.
                        if (roomForModel) ...[
                          Flexible(
                            child: SessionModelChip(
                              sessionId: sessionId,
                              maxLabelWidth: 72,
                            ),
                          ),
                          const SizedBox(width: Insets.sm),
                        ],
                        // The delivery actions take the room the other two do not:
                        // they are the part that has something new to say as the
                        // work moves, and the part that wraps when there is no room
                        // left. They wrap *within* this box, so a second run stays
                        // inside the group instead of pushing the ends around.
                        Expanded(
                          flex: 8,
                          child: DeliveryStrip(
                            sessionId: sessionId,
                            hostedOnTerminal: true,
                          ),
                        ),
                      ],
                      if (selected != null) ...[
                        const SizedBox(width: Insets.sm),
                        _ViewToggle(
                          onTerminal: onTerminal,
                          onChat: onChat,
                          onTerminalView: onTerminalView,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One tab in the strip.
///
/// The chip is a closure, not a widget: at a hundred tabs the strip must build
/// only the five or six on screen, and a list of built chips would be exactly
/// the eager `ListView(children: [...])` the performance audit named.
class _StripTab {
  const _StripTab({required this.active, required this.chip});

  final bool active;
  final Widget Function() chip;
}

/// The workbench tab strip.
///
/// **What overflow is for.** The app is built for a hundred live terminals
///, and a horizontal strip is hopeless at a hundred
/// tabs however well it scrolls — so the answer to "I cannot reach my tabs"
/// cannot be better scrolling. It is [TabPicker]: a filterable list of every
/// tab, reached from a button that appears exactly when the strip stops being
/// enough. The chevrons either side are the answer to the *other* half of the
/// complaint — that reaching a tab two along needed a horizontal mouse wheel —
/// and they only earn their place while the overflow is mild.
///
/// **Only tabs.** A selected session used to get a conversation chip here as
/// well as a toggle in the same row, so one tap in the Explorer looked like two
/// things opening. Its controls live under the surface now (see [_SessionBar]);
/// this is terminal tabs and nothing else.
///
/// What is left beside them — the terminal's own toolbar with **new tab** in
/// it, focus mode — sits outside the scrolling region, so no number of tabs can
/// push the way to make another one off the end of the strip.
class _TabStrip extends ConsumerWidget {
  const _TabStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tabs = _tabs(ref);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);

    // The strip is where a pane goes to stop being in a split. Dragging a chip
    // out of a region's header and dropping it here is the same verb as the
    // region menu's "Move to a new tab" and the palette's — the gesture the
    // whole redesign turns on, because a drag that only goes one way leaves
    // whatever it moved stranded.
    return DragTarget<TerminalDrag>(
      onWillAcceptWithDetails: (details) => switch (details.data) {
        PaneDrag(:final paneId) => sessions.isPaneInSplit(paneId),
        // A tab is already a tab; there is nothing here for it to become.
        TabDrag() => false,
      },
      onAcceptWithDetails: (details) {
        if (details.data case PaneDrag(:final paneId)) {
          sessions.movePaneToNewTab(paneId);
        }
      },
      builder: (context, candidate, _) => Container(
        height: Chrome.tabStrip,
        color: candidate.isEmpty
            ? scheme.surfaceContainerLow
            : scheme.primary.withValues(alpha: 0.08),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _TabRail(
                  tabs: tabs,
                  width: constraints.maxWidth,
                  activeIndex: tabs.indexWhere((tab) => tab.active),
                  // The toolbar's own verb, reached the way the toolbar reaches
                  // it. A second way to make a tab would be a second place for
                  // the default profile and the selected repository's directory
                  // to be decided.
                  onNewTab: () {
                    final terminal = TerminalActions(ref);
                    terminal.open(terminal.defaultProfile());
                  },
                  // The one place in the strip no chip can offer: the room
                  // after the last tab is how a tab is made last.
                  onMoveTabToEnd: (tabId) =>
                      sessions.reorderTab(tabId, tabs.length - 1),
                ),
              ),
            ),
            const TerminalToolbar(),
            const _ZenButton(),
            const SizedBox(width: Insets.xs),
          ],
        ),
      ),
    );
  }

  /// Every tab in the strip, left to right.
  ///
  /// **The shape of the strip, and nothing that happens inside a tab.** Watched
  /// narrowly on purpose: the whole [TerminalSessionsState] is republished
  /// whenever any pane's process dies, and at a hundred panes a process exiting
  /// is the common event — so watching it here rebuilt every chip in the strip
  /// for a dot that moved in one of them. Liveness is subscribed to per tab, by
  /// [_TabChip].
  List<_StripTab> _tabs(WidgetRef ref) {
    final tabs = ref.watch(terminalTabsProvider);
    final active = ref.watch(terminalActiveTabIdProvider);
    final onPanes = _showingPanes(ref);
    return [
      for (final (index, tab) in tabs.indexed)
        _StripTab(
          active: onPanes && tab.id == active,
          chip: () => _TabChip(
            tab: tab,
            selected: onPanes && tab.id == active,
            index: index,
            tabCount: tabs.length,
          ),
        ),
    ];
  }
}

/// The part of the tab strip no chip covers, so a test can aim at it.
///
/// Named rather than found by geometry because "the empty space" is the whole
/// subject of the gesture: a test that computed the coordinate itself would
/// stop testing the rule the moment the rule changed.
const kTabStripEmptySpace = Key('tab-strip/empty-space');

/// The insertion mark the strip draws while a tab is being dragged over it.
///
/// A drop that only announces itself by its result is a drop nobody aims: the
/// strip has to say *where this will land* while the button is still down, the
/// way every browser and editor does. Exactly one is ever on screen — a drag
/// has one active target at a time — so a test can find *the* mark and read its
/// rect to say which edge of which chip it is on.
const kTabDropMarker = Key('tab-strip/drop-marker');

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

/// One tab's chip, holding the strip's only watch on what happens *inside* a
/// tab.
///
/// A tab draws a liveness dot, so the strip cannot simply stop knowing about
/// liveness — but it can stop being told as a whole. Each chip subscribes to
/// its own panes through [terminalPaneLivenessProvider], so a process exiting
/// redraws that tab and leaves the other ninety-nine alone.
class _TabChip extends ConsumerWidget {
  const _TabChip({
    required this.tab,
    required this.selected,
    required this.index,
    required this.tabCount,
  });

  final TerminalTab tab;
  final bool selected;

  /// Where the strip laid this chip out, and how wide the row is. The chip
  /// itself reads no provider, so this is how it learns whether "close to the
  /// right" has anything to the right of it.
  final int index;
  final int tabCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final title = sessions.titleForTab(tab.id);
    final chip = TerminalTabChip(
      title: title,
      liveness: _liveness(ref),
      agentStatus: _agentActivity(ref),
      selected: selected,
      index: index,
      tabCount: tabCount,
      onTap: () => activateTerminalTab(ref, tab.id),
      onClose: () => sessions.closeTab(tab.id),
      onEnd: () => sessions.closeTab(tab.id, detach: false),
      onBulkClose: (scope) => _bulkClose(context, ref, scope),
    );

    // Dropping a tab on a region of a split moves it there — VS Code's gesture,
    // and half the reason a split can be made empty at all. The payload says
    // which of the two draggable things this is (see [TerminalDrag]), because a
    // region header can send a *pane* the other way; the keyboard reaches the
    // same verbs from the region's own "Move a tab here…" and from the command
    // palette, because a drag alone is not an affordance everybody has.
    return Draggable<TerminalDrag>(
      data: TabDrag(tab.id),
      feedback: _TabDragFeedback(title: title),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: _dropSlot(ref, chip),
    );
  }

  /// [chip], as the place another tab can be dropped into.
  ///
  /// The strip could not be rearranged at all until this, because a dragged tab
  /// had nothing to land *on*: the only target over the strip is the one around
  /// the whole of it, and that one refuses a tab by design — a tab is already a
  /// tab. So the chip is both ends of the gesture, a `Draggable` for the tab it
  /// carries and a `DragTarget` for the place it occupies.
  ///
  /// A *pane* is refused here rather than handled. A target that says no is
  /// skipped and the drop walks up to the strip's own, which is what turns a
  /// pane dragged out of a region header into a tab — so the two-way street
  /// stays exactly as wide as it was.
  ///
  /// The chip being dragged shows `childWhenDragging` in place of this, so a
  /// tab can never be dropped on itself and every drop that gets here moves
  /// something.
  Widget _dropSlot(WidgetRef ref, Widget chip) => DragTarget<TerminalDrag>(
    onWillAcceptWithDetails: (details) => details.data is TabDrag,
    onAcceptWithDetails: (details) {
      if (details.data case TabDrag(:final tabId)) {
        ref
            .read(terminalSessionsControllerProvider.notifier)
            .reorderTab(tabId, index);
      }
    },
    builder: (context, candidate, _) {
      final incoming = candidate.isEmpty ? null : candidate.first;
      if (incoming is! TabDrag) return chip;
      // Which edge the mark goes on is the direction of travel. A drop takes
      // this chip's index, so a tab arriving from the right lands *before*
      // this one and pushes it along; one from the left ends up after it.
      final from = ref
          .read(terminalTabsProvider)
          .indexWhere((candidate) => candidate.id == incoming.tabId);
      return _markedForDrop(context, chip, leading: from > index);
    },
  );

  /// Runs [scope], asking first when it would take a running session with it.
  ///
  /// The decision, stated once: a single close is a view action and detaching
  /// is right, but a bulk close is the user clearing the deck — and silently
  /// parking a dozen live agents in the background list is the outcome nobody
  /// wants. So the set is counted, and a set with anything live in it asks,
  /// with *end* as the default answer. A set with nothing live has no question
  /// to put, and simply closes.
  Future<void> _bulkClose(
    BuildContext context,
    WidgetRef ref,
    TabCloseScope scope,
  ) async {
    // Read now rather than trusting the index the chip was built with: a tab
    // can have gone between the menu opening and a row being picked.
    final tabs = ref.read(terminalTabsProvider);
    final at = tabs.indexWhere((candidate) => candidate.id == tab.id);
    if (at < 0) return;
    final ids = scope.apply([for (final tab in tabs) tab.id], at);
    if (ids.isEmpty) return;

    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    final closing = {for (final tab in tabs) tab.id: tab};
    final live = ids
        .where(
          (id) => closing[id]!.layout.panes.any(
            (paneId) => state.livenessOf(paneId).isLive,
          ),
        )
        .length;

    if (live == 0) {
      sessions.closeTabs(ids, activate: tab.id);
      return;
    }
    final choice = await confirmBulkTabClose(
      context,
      tabs: ids.length,
      live: live,
    );
    if (choice == null || !context.mounted) return;
    sessions.closeTabs(
      ids,
      detach: choice == BulkCloseChoice.keepRunning,
      activate: tab.id,
    );
  }

  /// The strongest liveness among this tab's panes — `livenessForTab`'s rule,
  /// asked pane by pane so a split's second pane is watched too.
  ///
  /// Every pane is watched rather than stopping at the first live one: the
  /// subscription set has to be the whole tab, or a pane this chip never asked
  /// about could die unnoticed.
  PaneLiveness _liveness(WidgetRef ref) {
    var strongest = PaneLiveness.exited;
    for (final paneId in tab.layout.panes) {
      final liveness = ref.watch(terminalPaneLivenessProvider(paneId));
      if (liveness == PaneLiveness.live) {
        strongest = PaneLiveness.live;
      } else if (liveness == PaneLiveness.restored &&
          strongest != PaneLiveness.live) {
        strongest = PaneLiveness.restored;
      }
    }
    return strongest;
  }

  /// What the agent in this tab is doing, or null when it holds none.
  ///
  /// Pane by pane for [_liveness]'s reason — the subscription set has to be the
  /// whole tab — and folded by [mostUrgentAgentActivity], which is where the
  /// choice between several agents in one tab is argued.
  ///
  /// Each of these watches is already narrowed twice over:
  /// [paneAgentActivityProvider] selects one key out of the shared
  /// paneId → sessionId map and then selects the status word out of the
  /// registry's report, so a 1.2 s cycle that reconfirms what a pane was
  /// already doing reaches no chip at all, and a cycle that changes one pane
  /// reaches one.
  AgentActivityStatus? _agentActivity(WidgetRef ref) => mostUrgentAgentActivity([
    for (final paneId in tab.layout.panes)
      ref.watch(paneAgentActivityProvider(paneId)),
  ]);
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

/// Whether the workbench is showing terminal **panes** right now.
///
/// Two surfaces can be up instead: the conversation, and the empty state a
/// selected session with no pane of ours gets. While either is, no terminal tab
/// is on screen at all — so none of them may draw as the active one, in the
/// strip or in the picker.
bool _showingPanes(WidgetRef ref) {
  // A pane appearing or ending changes the answer, and so does the launch that
  // rewrites `pane_id` on the row. Only the tab list, though: a *process* dying
  // cannot change which panes exist, and this is read from the tab strip on
  // every build.
  ref.watch(terminalTabsProvider);
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
  });
  final imported = ref.watch(selectedImportedSessionIdProvider);
  // The same fallback the workbench itself makes: with nothing selected it
  // still follows the pane on screen to its session, and that session has a
  // conversation the strip has to account for. See [_selectedSession].
  final selected =
      ref.watch(selectedSessionIdProvider) ??
      ref.watch(activePaneSessionIdProvider);
  // With no session at all the workbench is the terminal, whatever the flag
  // says — there is no second surface to be on.
  if (imported == null && selected == null) return true;
  if (!ref.watch(terminalVisibleProvider)) return false;
  // An imported CLI session has no pane of ours by definition.
  return imported == null && sessionTerminalPane(ref, selected!) != null;
}

/// Brings [tabId] to the front and makes sure the terminal is what the
/// workbench is showing: picking a tab from a strip or a list is a request to
/// *see* it, and it may well have been picked from the conversation — or from
/// the empty state of a session that is not in any tab at all
/// ([_releaseHijackedSelection]).
void activateTerminalTab(WidgetRef ref, String tabId) {
  ref.read(terminalSessionsControllerProvider.notifier).activateTab(tabId);
  ref.read(terminalVisibleProvider.notifier).set(true);
  _releaseHijackedSelection(ref);
}

/// Lets go of a selection that has no pane of ours, because the user has just
/// asked to see one that has.
///
/// [_NoPaneForSession] replaces the **whole** pane stack, which is right while
/// the selection is the only thing anyone has asked for and wrong the moment it
/// is not: a selected session nothing of ours runs held the middle of the
/// window against every live tab in the strip. Activating one moved the tab and
/// changed nothing on screen, and `_showingPanes` — false, because no tab was
/// showing — left every chip drawn inactive. That is the reported "after
/// closing a session with end session on a tab, other tabs are not accessible".
/// The terminal was healthy throughout; only the choice of surface was wrong.
///
/// **Cleared, not out-voted by a second mode.** `null` is the one value the
/// selection listeners in [WorkbenchView] ignore (`if (next != null)`), so this
/// cannot restart the fight where a tap opens a session's terminal and
/// something else undoes it. It is also what keeps the way back open: picking
/// the same row again is now a *change*, so the workbench opens it exactly as
/// it did the first time, empty state and all.
///
/// **Only the selection that is in the way.** One that has a pane is the
/// session the user is looking at, and the toggle to its conversation is
/// offered off the back of it; activating a tab must not quietly drop it.
void _releaseHijackedSelection(WidgetRef ref) {
  // An imported CLI session has no pane of ours by definition, so it is always
  // the paneless kind.
  if (ref.read(selectedImportedSessionIdProvider) != null) {
    ref.read(selectedImportedSessionIdProvider.notifier).select(null);
  }
  final selected = ref.read(selectedSessionIdProvider);
  if (selected != null && sessionTerminalPane(ref, selected) == null) {
    ref.read(selectedSessionIdProvider.notifier).select(null);
  }
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
          detail: sessions.livenessForTab(tab.id).isLive ? null : 'not running',
          icon: AppIcons.terminal,
          onSelect: () => activateTerminalTab(ref, tab.id),
        ),
        active: onPanes && tab.id == active,
        onClose: () => sessions.closeTab(tab.id),
      ),
  ];
}

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

/// The narrowest rail that can still draw both paging chevrons beside a tab.
///
/// One tab at its floor ([kMinTabWidth]) plus the two 30px icon buttons. Below
/// this the chevrons are dropped — see [_TabRailState.build].
const double _chevronsFitFrom = kMinTabWidth + 60;

/// The scrolling part of the strip, and the affordances for what will not fit.
class _TabRail extends StatefulWidget {
  const _TabRail({
    required this.tabs,
    required this.width,
    required this.activeIndex,
    required this.onNewTab,
    required this.onMoveTabToEnd,
  });

  final List<_StripTab> tabs;

  /// The room the tabs have, which decides how wide each draws and whether
  /// there is overflow at all. A field rather than something read from the
  /// context so a resize is a *prop change* the state can react to.
  final double width;

  final int activeIndex;

  /// Opens a terminal, for the gesture over the room the tabs did not use.
  final VoidCallback onNewTab;

  /// Sends a tab to the end of the strip, for a drop in that same room.
  final ValueChanged<String> onMoveTabToEnd;

  @override
  State<_TabRail> createState() => _TabRailState();
}

class _TabRailState extends State<_TabRail> {
  final _scroll = ScrollController();

  /// The strip's scroll position, and only while exactly one viewport owns it.
  ///
  /// `hasClients` is not that question. It is true the moment *any* viewport is
  /// attached, and for one frame there are two: the strip changes shape when it
  /// starts overflowing — a bare `ListView` becomes a row with chevrons around
  /// it — which moves the list to a new slot, and the outgoing viewport does not
  /// detach until that frame ends. `ScrollController.position` is
  /// `positions.single`, so it threw `Bad state: Too many elements` out of the
  /// chevron's builder on every launch, which is where the strip first learns
  /// it has overflowed.
  ///
  /// Null for that frame means the chevrons are drawn disabled, which is what
  /// they already do before the first layout.
  ScrollPosition? get _onePosition =>
      _scroll.positions.length == 1 ? _scroll.positions.first : null;

  @override
  void initState() {
    super.initState();
    // The controller has no position until the first layout, so neither the
    // reveal nor the chevrons can know anything until a frame has been drawn.
    _afterLayout();
  }

  @override
  void didUpdateWidget(_TabRail old) {
    super.didUpdateWidget(old);
    if (widget.activeIndex == old.activeIndex &&
        widget.width == old.width &&
        widget.tabs.length == old.tabs.length) {
      return;
    }
    _afterLayout();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Reveals the active tab and refreshes the chevrons once the frame this
  /// change belongs to has been laid out.
  ///
  /// Deferred for the reason quick open defers its own reveal: until the list
  /// has been laid out the scroll extents still describe the *previous* one,
  /// and clamping a target against those is how a strip ends up scrolled
  /// somewhere nobody asked for.
  void _afterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(_revealActive);
    });
  }

  /// Scrolls the active tab into view.
  ///
  /// The one thing a plain scrolling row does not do for itself, and the reason
  /// `Ctrl+PageUp`/`Ctrl+PageDown` were half-useless: stepping to a tab you
  /// cannot see is stepping to nowhere.
  void _revealActive() {
    final index = widget.activeIndex;
    final position = _onePosition;
    if (index < 0 || position == null) return;
    final extent = tabStripMetrics(widget.width, widget.tabs.length).extent;
    final target = revealOffset(
      position: position,
      leading: index * extent,
      extent: extent,
    );
    if (target != null) _scroll.jumpTo(target);
  }

  /// Scrolls most of a screenful, so a click lands somewhere recognisable
  /// rather than one tab along.
  void _page(bool forward) {
    final position = _onePosition;
    if (position == null) return;
    final step = position.viewportDimension * 0.8;
    _scroll.animateTo(
      (position.pixels + (forward ? step : -step)).clamp(
        0.0,
        position.maxScrollExtent,
      ),
      duration: Motion.base,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = tabStripMetrics(widget.width, widget.tabs.length);
    final list = ListView.builder(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.zero,
      itemExtent: metrics.extent,
      itemCount: widget.tabs.length,
      itemBuilder: (context, index) => widget.tabs[index].chip(),
    );
    if (!metrics.overflowing) return _overEmptySpace(list, metrics.extent);
    // The chevrons are the first thing to go when the rail itself runs out of
    // room, and this is not a preference — it is the only arrangement that
    // fits. Their own doc says they earn their place "while the overflow is
    // mild"; below [_chevronsFitFrom] the overflow is not mild, it is the rail
    // being squeezed to less than one tab by whatever shares the strip with it,
    // and a row of `chevron + Expanded + chevron + picker` needs ~100px of
    // chrome to draw. Built anyway it overflowed by 8.8px in a 640-wide window
    // — a striped bar across the tab strip, from adding one control at the
    // other end of the row.
    //
    // The picker stays at every width: it is "the only affordance here that
    // still works at a hundred", and the chevrons only page a list it can
    // filter.
    final chevrons = widget.width >= _chevronsFitFrom;
    return Row(
      children: [
        if (chevrons) _chevron(forward: false),
        Expanded(child: list),
        if (chevrons) _chevron(forward: true),
        _OverflowButton(count: widget.tabs.length),
      ],
    );
  }

  /// [list], with the strip's oldest unwritten gesture laid over whatever room
  /// the tabs did not use: **double-click the empty space to open a tab**, as
  /// VS Code, every browser and most terminals do.
  ///
  /// A sibling over the leftover pixels, and deliberately **not** a detector
  /// wrapped around the rail. An ancestor `onDoubleTap` joins the gesture arena
  /// for every pointer that lands on a chip, and it breaks the chip twice over:
  /// a double-click on a tab would open a new one instead of activating it,
  /// and — worse, because it is silent — every *single* click on a tab would
  /// wait out the 300 ms double-tap window before the chip's own `onTap` could
  /// win the arena. Here it covers only pixels no chip occupies, which is
  /// exactly the target the gesture is about.
  ///
  /// `Stack` hit-tests its children topmost-first and stops at the first that
  /// answers, so the list keeps every pointer over a chip and this keeps the
  /// rest. The `DragTarget` around the whole strip is an *ancestor* and stays
  /// on the hit-test path either way, so dropping a pane on the empty space
  /// still turns it into a tab.
  ///
  /// Only reached when the tabs fit. An overflowing rail has no empty space by
  /// definition, and the arm above returns the row of chevrons instead.
  Widget _overEmptySpace(Widget list, double extent) {
    final free = widget.width - extent * widget.tabs.length;
    // Half a pixel of slack: a rail whose tabs exactly fill it has no target,
    // and a zero-width one would be a control nobody can hit.
    if (free <= 0.5) return list;
    return Stack(
      children: [
        list,
        Positioned(
          key: kTabStripEmptySpace,
          left: widget.width - free,
          top: 0,
          bottom: 0,
          right: 0,
          // Two gestures over the same pixels, and they do not compete: the
          // double-click is a pointer gesture and the drop is resolved by the
          // drag avatar's own hit test. The target is the *outer* of the two so
          // the detector underneath still answers the hit that puts both of
          // them on the path — and a pane is refused here so it carries on up
          // to the strip's target and becomes a tab, as it always has.
          child: DragTarget<TerminalDrag>(
            onWillAcceptWithDetails: (details) => details.data is TabDrag,
            onAcceptWithDetails: (details) {
              if (details.data case TabDrag(:final tabId)) {
                widget.onMoveTabToEnd(tabId);
              }
            },
            builder: (context, candidate, _) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: widget.onNewTab,
              child: candidate.isEmpty
                  ? const SizedBox.expand()
                  // Against the last chip rather than out in the middle of the
                  // empty room: the mark says where the tab lands, and it lands
                  // immediately after the tabs, not where the pointer is.
                  : _markedForDrop(
                      context,
                      const SizedBox.expand(),
                      leading: true,
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _chevron({required bool forward}) => ListenableBuilder(
    listenable: _scroll,
    builder: (context, _) {
      final position = _onePosition;
      // A position exists from the moment the controller is attached, but its
      // pixels and extents do not exist until the viewport has been laid out —
      // and reading `maxScrollExtent` before then throws. Both chevrons are
      // simply off for that one frame.
      //
      // Half a pixel of slack at the ends: a scroll that has arrived can sit a
      // rounding error short, and a chevron that stays enabled at the end is a
      // button that does nothing.
      final can =
          position != null &&
          position.hasPixels &&
          position.hasContentDimensions &&
          (forward
              ? position.pixels < position.maxScrollExtent - 0.5
              : position.pixels > 0.5);
      // Shaped like the terminal toolbar's buttons at the other end of the
      // strip rather than like a tab's own close button: these are chrome that
      // acts on the strip, and they are the two the mouse aims at most.
      return IconButton(
        tooltip: forward ? 'Later tabs' : 'Earlier tabs',
        icon: Icon(
          forward ? AppIcons.caretRight : AppIcons.caretLeft,
          size: Chrome.icon,
        ),
        onPressed: can ? () => _page(forward) : null,
      );
    },
  );
}

/// The way to every tab the strip cannot show, and the only affordance here
/// that still works at a hundred.
class _OverflowButton extends ConsumerWidget {
  const _OverflowButton({required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      // The name Narrator reads, so it has to say what the control *does*, not
      // only how many there are.
      message: 'All $count tabs — filter and switch',
      child: InkWell(
        onTap: () => TabPicker.show(context, terminalTabEntries),
        child: Container(
          height: Chrome.tabStrip,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.listMagnifyingGlass,
                size: Chrome.icon,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two renderings of one session. Not a navigation control: both sides show
/// the same record, the same PTY and the same lifecycle.
///
/// Labelled in words as well as icons, and the only way to the conversation now
/// that no tab stands for it. The terminal is where a session opens, so the way
/// back to its transcript cannot be a chord and a hover — it has to be a thing
/// on the chrome that says what it is.
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
              // Padded rather than fixed at 22px: the halves have to grow with
              // the ambient text scale like the permission control and the
              // actions beside them, or the row stops sharing a centre-line at
              // exactly the sizes an accessibility setting asks for.
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: kBarControlPad,
              ),
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

    // No padding of its own: the bar spaces its own row, and a control whose
    // bounds include a margin is a control whose centre-line is a guess.
    //
    // A `Container` with the border on its decoration rather than a `ClipRRect`
    // over a `DecoratedBox`, because only the first *reserves* the border's
    // pixel: the second painted the outline inside the halves and left the
    // toggle two pixels shorter than the permission control and the actions,
    // which is one pixel of drift on the centre-line the row is built around.
    return Container(
      clipBehavior: Clip.antiAlias,
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
          half(AppIcons.chatCircle, 'Chat', 'Chat view', !onTerminal, onChat),
        ],
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
