import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/detail/presentation/workbench_session_view.dart';
import '../../features/explorer/application/explorer_actions.dart';
import '../../features/explorer/application/session_context.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/sessions/presentation/approval_request_card.dart';
import '../../features/sessions/presentation/delivery_strip.dart';
import '../../features/sessions/presentation/permission_mode_chip.dart';
import '../../features/sessions/presentation/session_transcript_view.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';
import 'tab_picker.dart';

/// The switcher between the two surfaces. Named so a test can read which one is
/// painted on a given frame without going through whatever either one renders.
const Key kWorkbenchSurfaces = ValueKey('workbench-surfaces');

/// The primary content area: one tab strip across the top, the work underneath.
///
/// Loop 47 moved the terminal here from a 280px bottom dock. A dock is right for
/// an *editor*-primary app; Chitragupta decided to be terminal-primary, and none
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
/// lifecycle, an approval that is blocking the agent) reachable only from
/// there. Now a selection opens the session's pane, and those controls are
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
      // A restored workspace can put an agent pane on screen before anything is
      // selected; the side panel should describe that session, not the row the
      // Explorer happens to highlight first.
      if (active != null) ref.read(sessionContextProvider).follow(active);
      if (selected != null) _showSurfaceFor(_shownPane);
    });
  }

  /// **The only write of `false` in the app.** Wired to the labelled Chat half
  /// of the bar's toggle and to nothing else, which is what makes "a tap never
  /// opens the conversation" a property rather than a race won.
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
  /// No branch on whether it has a pane. `sessionTerminalPane` is still asked,
  /// but only to decide *which* pane to focus — a session that has none gets
  /// the terminal surface with [_NoPaneForSession] on it, which is the one
  /// place that says so, in the same words the conversation's own empty hint
  /// reads off the same helper.
  void _openSession(String sessionId) =>
      _showSurfaceFor(sessionTerminalPane(ref, sessionId));

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
    _shownPane = paneId;
    // Losing a pane is not a reason to move: the terminal surface says what
    // happened. Gaining one is, or the session would be off screen.
    if (paneId != null) _showTerminalFor(paneId);
  }

  void _showSurfaceFor(String? paneId) {
    _shownPane = paneId;
    _showTerminalFor(paneId);
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
      if (next != null) _showSurfaceFor(null);
    });
    // ...and the pane the selected session has can arrive after the tap that
    // selected it, or go away under it. Both of these move it: the terminal's
    // state says whether an instance exists, the revision says which pane the
    // row points at. See [_followSessionPane].
    ref.listen(terminalSessionsControllerProvider, (_, _) {
      _followSessionPane();
    });
    ref.listen(sessionsRevisionProvider, (_, _) => _followSessionPane());
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _TabStrip(),
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
                    key: kWorkbenchSurfaces,
                    index: onTerminal ? 0 : 1,
                    children: [
                      _TerminalSurface(session: session),
                      const WorkbenchSessionView(),
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
          onTerminalView: () => _showTerminalFor(session?.paneId),
        ),
      ],
    );
  }

  /// The session the Explorer has selected, if any, as the workbench needs it:
  /// a title, whether it has a pane of ours, and whether it is one of ours at
  /// all (imported CLI sessions have no pane and no live status).
  _WorkbenchSession? _selectedSession() {
    ref.watch(sessionsRevisionProvider);
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

/// The terminal rendering of a session: the panes, and the one thing that has
/// to be answered before anything else offered around them will be read.
///
/// The approval card is the chat view's own widget, not a lookalike — one
/// [ApprovalRequestCard] exists in the app, so the two views cannot offer
/// different answers. It sits *below* the panes because that is where the thing
/// it responds to is: an agent's prompt is drawn at the bottom of its terminal,
/// so the buttons that answer it are the next thing under it rather than a
/// header the eye has to travel back up to. Everything else that belongs to the
/// session is one row further down, in [_SessionBar].
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
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: TerminalPaneStack()),
        _PaneApproval(),
      ],
    );
  }
}

/// What the terminal surface shows for a session nothing of ours is running.
///
/// This is what lets "a tap always lands on the terminal" be honest rather than
/// a lie told by showing an unrelated tab. Every sentence is read off
/// `sessionTerminalPane` and the row itself, which is the same pair the
/// conversation's empty hint reads, so the two surfaces cannot describe one
/// session differently.
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
              Icon(AppIcons.terminal, size: 32, color: scheme.onSurfaceVariant),
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
                      icon: const Icon(AppIcons.playCircle, size: 16),
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

/// The approval blocking the pane on screen, drawn under it.
///
/// Above the session bar for the same reason it is above the delivery row in
/// the conversation: it is the thing blocking the session, and nothing else
/// offered here will be read until the agent's prompt is answered. It follows
/// the focused pane, so a shell tab has nothing to answer and draws nothing —
/// and it draws nothing until there *is* an approval, because nothing here may
/// reserve terminal rows for something it might one day have to say.
class _PaneApproval extends ConsumerWidget {
  const _PaneApproval();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(activePaneSessionIdProvider);
    if (sessionId == null) return const SizedBox.shrink();
    return ApprovalRequestCard(sessionId: sessionId, hostedOnTerminal: true);
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
          child: Row(
            children: [
              if (sessionId == null)
                const Spacer()
              else ...[
                Padding(
                  padding: const EdgeInsets.only(right: Insets.sm),
                  child: PermissionModeChip(sessionId: sessionId),
                ),
                // The delivery lifecycle takes the room the other two do not:
                // it is the part that has something new to say as the work
                // moves, and the part that wraps when there is no room left.
                Expanded(
                  child: DeliveryStrip(
                    sessionId: sessionId,
                    hostedOnTerminal: true,
                  ),
                ),
              ],
              if (selected != null)
                _ViewToggle(
                  onTerminal: onTerminal,
                  onChat: onChat,
                  onTerminalView: onTerminalView,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The widest a tab draws, matching [WorkbenchTabChip]'s own cap, and the
/// narrowest it shrinks to before the strip gives up and scrolls.
///
/// The floor is what makes overflow *rare*: a tab has to keep its liveness
/// mark, its close button and enough of its title to be told from the tab
/// beside it, and 112px is where that stops being true.
const double kMaxTabWidth = 220.0;
const double kMinTabWidth = 112.0;

/// How wide each tab draws in a strip [width] logical pixels wide holding
/// [count] of them, and whether even at their narrowest they do not fit.
///
/// **Tabs are uniform**, the way a browser's and a terminal's are: they share
/// the room evenly and shrink as more open, rather than each taking whatever
/// its title happens to need. Two properties follow, and both are the reason
/// for it. Overflow becomes a *predicate* — `count * kMinTabWidth > width` —
/// instead of something only a laid-out row can answer; and the offset of tab
/// *i* is `i * extent`, which is what lets the strip scroll a tab into view
/// without having built the chip first. A hundred tabs are virtualised, so the
/// tab a chord just moved to is usually one that does not exist yet.
({double extent, bool overflowing}) tabStripMetrics(double width, int count) {
  if (count <= 0) return (extent: kMaxTabWidth, overflowing: false);
  return (
    extent: (width / count).clamp(kMinTabWidth, kMaxTabWidth),
    overflowing: count * kMinTabWidth > width,
  );
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
/// (`docs/ARCHITECTURE.md`), and a horizontal strip is hopeless at a hundred
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

    return Container(
      height: Chrome.tabStrip,
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => _TabRail(
                tabs: tabs,
                width: constraints.maxWidth,
                activeIndex: tabs.indexWhere((tab) => tab.active),
              ),
            ),
          ),
          const TerminalToolbar(),
          const _ZenButton(),
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }

  /// Every tab in the strip, left to right.
  ///
  /// Deliberately cheap — a title and a liveness per tab, no database. It runs
  /// on every terminal state publish, which at a hundred panes is often.
  List<_StripTab> _tabs(WidgetRef ref) {
    final terminals = ref.watch(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final onPanes = _showingPanes(ref);
    final active = terminals.activeTabId;
    return [
      for (final tab in terminals.tabs)
        _StripTab(
          active: onPanes && tab.id == active,
          chip: () => TerminalTabChip(
            title: sessions.titleForTab(tab.id),
            liveness: sessions.livenessForTab(tab.id),
            selected: onPanes && tab.id == active,
            onTap: () => activateTerminalTab(ref, tab.id),
            onClose: () => sessions.closeTab(tab.id),
            onEnd: () => sessions.closeTab(tab.id, detach: false),
          ),
        ),
    ];
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
  // rewrites `pane_id` on the row.
  ref.watch(terminalSessionsControllerProvider);
  ref.watch(sessionsRevisionProvider);
  final imported = ref.watch(selectedImportedSessionIdProvider);
  final selected = ref.watch(selectedSessionIdProvider);
  // With nothing selected the workbench is the terminal, whatever the flag
  // says — there is no second surface to be on.
  if (imported == null && selected == null) return true;
  if (!ref.watch(terminalVisibleProvider)) return false;
  // An imported CLI session has no pane of ours by definition.
  return imported == null && sessionTerminalPane(ref, selected!) != null;
}

/// Brings [tabId] to the front and makes sure the terminal is what the
/// workbench is showing: picking a tab from a strip or a list is a request to
/// *see* it, and it may well have been picked from the conversation.
void activateTerminalTab(WidgetRef ref, String tabId) {
  ref.read(terminalSessionsControllerProvider.notifier).activateTab(tabId);
  ref.read(terminalVisibleProvider.notifier).set(true);
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
  // Adopting a pane, or launching into one, rewrites `pane_id` on the row.
  ref.watch(sessionsRevisionProvider);
  final titles = <String, String>{
    for (final record in ref.read(sessionDaoProvider).getAll())
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

/// The scrolling part of the strip, and the affordances for what will not fit.
class _TabRail extends StatefulWidget {
  const _TabRail({
    required this.tabs,
    required this.width,
    required this.activeIndex,
  });

  final List<_StripTab> tabs;

  /// The room the tabs have, which decides how wide each draws and whether
  /// there is overflow at all. A field rather than something read from the
  /// context so a resize is a *prop change* the state can react to.
  final double width;

  final int activeIndex;

  @override
  State<_TabRail> createState() => _TabRailState();
}

class _TabRailState extends State<_TabRail> {
  final _scroll = ScrollController();

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
    if (index < 0 || !_scroll.hasClients) return;
    final extent = tabStripMetrics(widget.width, widget.tabs.length).extent;
    final target = revealOffset(
      position: _scroll.position,
      leading: index * extent,
      extent: extent,
    );
    if (target != null) _scroll.jumpTo(target);
  }

  /// Scrolls most of a screenful, so a click lands somewhere recognisable
  /// rather than one tab along.
  void _page(bool forward) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
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
    if (!metrics.overflowing) return list;
    return Row(
      children: [
        _chevron(forward: false),
        Expanded(child: list),
        _chevron(forward: true),
        _OverflowButton(count: widget.tabs.length),
      ],
    );
  }

  Widget _chevron({required bool forward}) => ListenableBuilder(
    listenable: _scroll,
    builder: (context, _) {
      final position = _scroll.hasClients ? _scroll.position : null;
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
      padding: const EdgeInsets.only(left: Insets.sm),
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
