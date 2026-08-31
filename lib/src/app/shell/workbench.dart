import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/detail/presentation/workbench_session_view.dart';
import '../../features/explorer/application/session_context.dart';
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
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';
import 'tab_picker.dart';

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
///
/// **The surface follows the session, not the tap.** Loop 85 decided it once,
/// on the selection changing — but the Explorer selects a session *before* it
/// reveals or resumes it, so that decision was made while the session still had
/// no pane and the terminal arrived after the conversation had already been
/// painted. One tap, two surfaces, which is what the user reported twice. The
/// same question is now re-asked whenever its inputs move (see
/// `_followSessionPane`), and the resting state is the terminal rather than
/// something every path has to switch to.
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

  /// The surface the mount catch-up is *about* to select, until it has.
  ///
  /// Riverpod forbids writing a provider from `initState` — two widgets in one
  /// frame would read different states — and reattaching a pane there would
  /// republish the terminal while the tree around us is still building. So the
  /// catch-up runs after the frame. Which leaves the frame itself: whatever the
  /// provider happens to hold gets painted, and is then replaced. That is one
  /// tap showing two surfaces, so the first build **reads** the answer the
  /// catch-up will write instead of waiting for it.
  bool? _surfaceOnMount;

  @override
  void initState() {
    super.initState();
    // A session can already be selected when the workbench mounts — the shell
    // rebuilding around it, or a selection made by something that ran first.
    // The listener in `build` only fires on a *change*, so without this the
    // one case the whole loop is about would be the case that lands on chat.
    final selected = ref.read(selectedSessionIdProvider);
    final active = ref.read(activePaneSessionIdProvider);
    if (selected == null && active == null) return;
    if (selected != null) {
      _shownPane = sessionTerminalPane(ref, selected);
      _surfaceOnMount = _shownPane != null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A restored workspace can put an agent pane on screen before anything is
      // selected; the side panel should describe that session, not the row the
      // Explorer happens to highlight first.
      if (active != null) ref.read(sessionContextProvider).follow(active);
      if (selected != null) _showSurfaceFor(_shownPane);
      // Cleared through `setState` rather than on the back of the write above:
      // the write is a no-op whenever it agrees with what the provider already
      // held, and this must stop standing in for it either way.
      setState(() => _surfaceOnMount = null);
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
    _showSurfaceFor(sessionTerminalPane(ref, sessionId));
  }

  /// Keeps the surface on the selected session's *eventual* state.
  ///
  /// The fallback above is answered at the moment of the tap, and at that
  /// moment the answer is often provisional: `ExplorerActions.openNative`
  /// selects the row **before** it reveals or resumes it, so a session being
  /// brought back has no pane yet when the surface is chosen. Deciding once and
  /// leaving it there is what made one tap open the conversation and then the
  /// terminal — from the user's seat, both.
  ///
  /// So the same question is asked again whenever its two inputs move: the
  /// terminal's own state (a pane created, adopted, restored, detached or
  /// ended) and `sessions.pane_id` (which a launch rewrites, then bumps the
  /// revision). Memoised on [_shownPane], so a publish that changes nothing
  /// about this session changes nothing here — in particular it never overrules
  /// a user who has deliberately switched to the conversation.
  void _followSessionPane() {
    final sessionId = ref.read(selectedSessionIdProvider);
    if (sessionId == null) return;
    final paneId = sessionTerminalPane(ref, sessionId);
    if (paneId == _shownPane) return;
    _showSurfaceFor(paneId);
  }

  void _showSurfaceFor(String? paneId) {
    _shownPane = paneId;
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
      if (next != null) ref.read(sessionContextProvider).follow(next);
    });

    final scheme = Theme.of(context).colorScheme;
    final session = _selectedSession();
    final wantsTerminal = ref.watch(terminalVisibleProvider);
    // With nothing to read, the workbench is the terminal — an empty middle
    // would be worse than the surface the app is primarily about.
    final onTerminal = (_surfaceOnMount ?? wantsTerminal) || session == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
          session: session,
          onTerminal: onTerminal,
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
    // A pane appearing or ending changes whether this session has a terminal at
    // all, which is what decides whether the strip offers the toggle. Watched
    // rather than read so the strip cannot keep offering a surface that is gone.
    ref.watch(terminalSessionsControllerProvider);
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
    final sessionId = ref.watch(activePaneSessionIdProvider);
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
/// Everything to the right of the tabs — the permission chip, the view toggle,
/// the terminal's own toolbar with **new tab** in it, focus mode — sits outside
/// the scrolling region, so no number of tabs can push the way to make another
/// one off the end of the strip.
class _TabStrip extends ConsumerWidget {
  const _TabStrip({
    required this.session,
    required this.onTerminal,
    required this.onShowSession,
    required this.onShowTerminal,
  });

  final _WorkbenchSession? session;
  final bool onTerminal;
  final VoidCallback onShowSession;
  final ValueChanged<String?> onShowTerminal;

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
                entries: _entries,
              ),
            ),
          ),
          // The permission mode belongs to the session, not to one of its two
          // renderings. It was on the chat composer only, so the same control
          // was readable on one view and invisible on the other; this is the
          // same widget reading the same `effectivePermissionFor`, so the two
          // views cannot disagree.
          if (onTerminal) const _PanePermissionChip(),
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

  /// Every tab in the strip, left to right: the selected session's conversation
  /// when there is one, then the terminal tabs.
  ///
  /// Deliberately cheap — a title and a liveness per tab, no database. It runs
  /// on every terminal state publish, which at a hundred panes is often.
  List<_StripTab> _tabs(WidgetRef ref) {
    final terminals = ref.watch(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final active = terminals.activeTabId;
    return [
      if (session != null)
        _StripTab(
          active: !onTerminal,
          chip: () => WorkbenchTabChip(
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
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              padding: EdgeInsets.zero,
              icon: const Icon(AppIcons.x),
              onPressed: () => _closeConversation(ref),
            ),
          ),
        ),
      for (final tab in terminals.tabs)
        _StripTab(
          active: onTerminal && tab.id == active,
          chip: () => TerminalTabChip(
            title: sessions.titleForTab(tab.id),
            liveness: sessions.livenessForTab(tab.id),
            selected: onTerminal && tab.id == active,
            onTap: () => _activate(sessions, tab.id),
            onClose: () => sessions.closeTab(tab.id),
            onEnd: () => sessions.closeTab(tab.id, detach: false),
          ),
        ),
    ];
  }

  /// The same tabs as [_tabs], as [TabPicker] lists them.
  ///
  /// Built only while the picker is open, because this is the expensive half:
  /// telling two `zsh` tabs apart means knowing which session runs in which
  /// pane, and that is a query the strip itself never needs.
  List<TabEntry> _entries(WidgetRef ref) {
    final terminals = ref.watch(terminalSessionsControllerProvider);
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    // Adopting a pane, or launching into one, rewrites `pane_id` on the row.
    ref.watch(sessionsRevisionProvider);
    final titles = <String, String>{
      for (final record in ref.read(sessionDaoProvider).getAll())
        if (record.paneId != null) record.paneId!: record.title,
    };
    final active = terminals.activeTabId;
    return [
      if (session != null)
        TabEntry(
          item: QuickOpenItem(
            id: 'conversation/${session!.id}',
            group: QuickOpenGroup.tabs,
            title: session!.title,
            subtitle: 'Conversation',
            icon: AppIcons.chatCircle,
            onSelect: onShowSession,
          ),
          active: !onTerminal,
        ),
      for (final tab in terminals.tabs)
        TabEntry(
          item: QuickOpenItem(
            id: 'tab/${tab.id}',
            group: QuickOpenGroup.tabs,
            title: sessions.titleForTab(tab.id),
            subtitle: _whereabouts(tab, titles, sessions),
            detail: sessions.livenessForTab(tab.id).isLive
                ? null
                : 'not running',
            icon: AppIcons.terminal,
            onSelect: () => _activate(sessions, tab.id),
          ),
          active: onTerminal && tab.id == active,
          onClose: () => sessions.closeTab(tab.id),
        ),
    ];
  }

  /// Where a tab is: the session running in its focused pane, the directory
  /// that pane is in, or both.
  ///
  /// Without it a window full of `zsh` tabs is a list of identical rows, and a
  /// picker you cannot pick from is not an answer to anything.
  static String? _whereabouts(
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

  void _activate(TerminalSessionsController sessions, String tabId) {
    sessions.activateTab(tabId);
    onShowTerminal(null);
  }

  void _closeConversation(WidgetRef ref) {
    ref.read(selectedSessionIdProvider.notifier).select(null);
    ref.read(selectedImportedSessionIdProvider.notifier).select(null);
  }
}

/// The scrolling part of the strip, and the affordances for what will not fit.
class _TabRail extends StatefulWidget {
  const _TabRail({
    required this.tabs,
    required this.width,
    required this.activeIndex,
    required this.entries,
  });

  final List<_StripTab> tabs;

  /// The room the tabs have, which decides how wide each draws and whether
  /// there is overflow at all. A field rather than something read from the
  /// context so a resize is a *prop change* the state can react to.
  final double width;

  final int activeIndex;
  final List<TabEntry> Function(WidgetRef ref) entries;

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
        _OverflowButton(count: widget.tabs.length, entries: widget.entries),
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
  const _OverflowButton({required this.count, required this.entries});

  final int count;
  final List<TabEntry> Function(WidgetRef ref) entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      // The name Narrator reads, so it has to say what the control *does*, not
      // only how many there are.
      message: 'All $count tabs — filter and switch',
      child: InkWell(
        onTap: () => TabPicker.show(context, entries),
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

/// The permission chip for the agent pane the terminal view is showing.
///
/// Follows the focused pane rather than the tree, for the reason given on
/// [activePaneSessionIdProvider]. A shell tab draws nothing.
class _PanePermissionChip extends ConsumerWidget {
  const _PanePermissionChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(activePaneSessionIdProvider);
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
