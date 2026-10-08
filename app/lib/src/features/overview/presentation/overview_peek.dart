import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/git.dart' show FileDiffStat;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart';
import '../../../app/shell/session_more_button.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/presentation/imported_session_view.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../git/presentation/diff_view.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_active_model_providers.dart';
import '../../sessions/application/session_chat_source.dart'
    show ChatsShownOutsideGroups, chatsShownOutsideGroupsProvider;
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../../sessions/presentation/delivery_strip.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../../sessions/presentation/operator_chip.dart';
import '../../sessions/presentation/session_agent_chip.dart';
import '../../sessions/presentation/session_transcript_view.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/terminal_theme_controller.dart';
import '../../terminal/presentation/pane_frame.dart';
import '../../terminal/presentation/terminal_actions.dart';
import '../../terminal/presentation/terminal_theme_colors.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_seen.dart';
import '../application/overview_tiles.dart';
import 'overview_card_parts.dart';
import 'overview_pins.dart';
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';

/// The session's own conversation, as its tab draws it: streaming, with its
/// asks and its composer — which, for a session nothing runs, resumes it
/// here rather than in a tab. A test puts a stand-in here.
final overviewPeekChatProvider =
    Provider<Widget Function(WorkspaceSessionEntry entry, DateTime? seenUntil)>(
      (ref) =>
          (entry, seenUntil) => entry.native != null
          ? SessionTranscriptView(
              key: ValueKey('overview-peek-chat:${entry.id}'),
              sessionId: entry.id,
              seenUntil: seenUntil,
              resumesInBackground: true,
            )
          : ImportedSessionView(
              key: ValueKey('overview-peek-chat:${entry.id}'),
              sessionId: entry.id,
            ),
    );

/// The pane that hosts [String] session's terminal on this machine, or null.
final overviewSessionPaneProvider = Provider.autoDispose
    .family<String?, String>(
      (ref, sessionId) => ref.watch(paneSessionsProvider).paneOf(sessionId),
    );

/// **The peek**: the session's real, live chat — its asks and composer as
/// its own tab has them — with its terminal, its files and its sub-sessions
/// beside it, under a header with Stop, Archive and Open tab.
class OverviewPeek extends ConsumerStatefulWidget {
  const OverviewPeek({
    required this.card,
    required this.onClose,
    this.onPeek,
    this.onPrevious,
    this.onNext,
    this.beside = false,
    this.compact = false,
    super.key,
  });

  final OverviewCard card;
  final VoidCallback onClose;

  /// A phone's page: a slim bar — back, the agent, one line of title, the
  /// state, Stop or Resume and Open tab — with the rest in ⋯, and the chat
  /// given the screen.
  final bool compact;

  /// The second of two peeks side by side: its tab is its own.
  final bool beside;

  /// Another session — a sub-session or the parent — was opened from here.
  final ValueChanged<OverviewCard>? onPeek;

  /// ↑ and ↓: the session before and after this one; null at an end.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  ConsumerState<OverviewPeek> createState() => _OverviewPeekState();
}

class _OverviewPeekState extends ConsumerState<OverviewPeek> {
  /// When the owner last looked, before this look: fixed while it is open.
  DateTime? _seenUntil;
  late final OverviewSeenController _seen;
  var _besideTab = OverviewPeekTab.chat;

  @override
  void initState() {
    super.initState();
    _seen = ref.read(overviewSeenProvider.notifier);
    final id = widget.card.id;
    _seenUntil = ref.read(overviewSeenProvider)[id];
    // Marked after the frame: a provider is not changed while one builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seen.markSeen(id, ref.read(clockProvider).nowUtc());
    });
  }

  @override
  void dispose() {
    // Everything that came while it was open has been seen too; marked once
    // the tree is done, which a provider may not be changed under.
    final seen = _seen;
    final id = widget.card.id;
    final at = DateTime.now().toUtc();
    Future.microtask(() => seen.markSeen(id, at));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final entry = card.entry;
    final id = entry.id;
    final focus = ref.read(overviewFocusProvider.notifier);
    final pane = ref.watch(overviewSessionPaneProvider(id));
    final children = byUrgency(
      ref.watch(overviewBoardProvider.select((b) => b.children[id])) ??
          const <OverviewCard>[],
    );
    final files = ref.watch(overviewChangedFilesProvider(id)).asData?.value;
    final editing =
        !widget.beside &&
        ref.watch(
          overviewFocusProvider.select((f) => f.editing && f.peeked == id),
        );
    final asked = widget.beside
        ? _besideTab
        : ref.watch(overviewFocusProvider.select((f) => f.tab));
    final tabs = [
      OverviewPeekTab.chat,
      if (pane != null) OverviewPeekTab.terminal,
      OverviewPeekTab.files,
      if (children.isNotEmpty) OverviewPeekTab.subSessions,
    ];
    final tab = tabs.contains(asked) ? asked : OverviewPeekTab.chat;
    String label(OverviewPeekTab t) => switch (t) {
      OverviewPeekTab.chat => 'Chat',
      OverviewPeekTab.terminal => 'Terminal',
      OverviewPeekTab.files =>
        files == null || files.isEmpty ? 'Files' : 'Files · ${files.length}',
      OverviewPeekTab.subSessions => 'Sub-sessions · ${children.length}',
    };

    final Widget body = switch (tab) {
      OverviewPeekTab.chat => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (editing && card.column == BoardColumn.needsYou)
            Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: BoardEditCommand(sessionId: id, onDone: focus.stopEditing),
            ),
          Expanded(
            child: _ShownChat(
              child: ref.watch(overviewPeekChatProvider)(entry, _seenUntil),
            ),
          ),
          // Where the session's own tab has them: under the conversation.
          if (entry.native != null) OverviewPeekControls(sessionId: id),
        ],
      ),
      OverviewPeekTab.terminal => _PeekTerminal(paneId: pane!),
      OverviewPeekTab.files => _PeekFiles(card: card, files: files),
      OverviewPeekTab.subSessions => ListView(
        key: const ValueKey('overview-peek-subs'),
        padding: const EdgeInsets.all(Insets.md),
        children: [
          Text(
            subSessionSummary(children),
            style: UiDensity.of(context).muted(Theme.of(context)),
          ),
          const SizedBox(height: Insets.xs),
          for (final child in children)
            _PeekSubSession(card: child, onTap: widget.onPeek),
        ],
      ),
    };

    return Semantics(
      container: true,
      label: 'Peek: ${entry.title}',
      child: Material(
        key: const ValueKey('overview-peek'),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.compact)
              _PeekBar(
                card: card,
                onClose: widget.onClose,
                onPeek: widget.onPeek,
                onPrevious: widget.onPrevious,
                onNext: widget.onNext,
              )
            else
              _PeekHeader(
                card: card,
                onClose: widget.onClose,
                onPeek: widget.onPeek,
                onPrevious: widget.onPrevious,
                onNext: widget.onNext,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                0,
                Insets.md,
                Insets.sm,
              ),
              child: _PeekTabRow(
                scrolls: widget.compact,
                child: CompactSegmented<OverviewPeekTab>(
                  key: const ValueKey('overview-peek-tabs'),
                  segments: [
                    for (final t in tabs)
                      ButtonSegment(
                        value: t,
                        label: Text(
                          label(t),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          key: ValueKey('overview-peek-tab:${t.name}'),
                        ),
                      ),
                  ],
                  selected: tab,
                  onChanged: widget.beside
                      ? (t) => setState(() => _besideTab = t)
                      : focus.showTab,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('overview-peek-body'),
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Title, where it runs, ↑ ↓ ✕, the state, Stop / Archive / Open tab, and
/// the plan.
class _PeekHeader extends ConsumerWidget {
  const _PeekHeader({
    required this.card,
    required this.onClose,
    this.onPeek,
    this.onPrevious,
    this.onNext,
  });

  final OverviewCard card;
  final VoidCallback onClose;
  final ValueChanged<OverviewCard>? onPeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final id = entry.id;
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final agent = watchOverviewAgentName(ref, card);
    // Left out until the agent says which model it runs.
    final model = ref.watch(sessionActiveModelProvider(id))?.label;
    final place = watchOverviewPlace(ref, card);
    final directory = entry.directory;
    final branch = directory == null
        ? null
        : ref.watch(overviewKnownBranchProvider(directory));
    final native = entry.native;
    final live = native != null && sessionHasLiveProcess(ref, id);
    final archivable =
        native != null && !native.isArchived && !sessionIsLive(ref, native);
    final resumable = watchOverviewResumable(ref, card);
    final plan = ref.watch(overviewGlanceProvider(id)).asData?.value?.plan;
    final parentId = native?.parentSessionId;
    final parent = parentId == null
        ? null
        : overviewCardOf(ref.watch(overviewBoardProvider), parentId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.sm,
        Insets.xs,
        Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (parent != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('overview-peek-parent'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                ),
                onPressed: onPeek == null ? null : () => onPeek!(parent),
                child: Text(
                  '↑ Sub-session of ${parent.entry.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Insets.xxs),
                child: OverviewAgentRing(card: card),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      [
                        ?agent,
                        ?model,
                        if (place.isNotEmpty) place,
                        ?branch,
                      ].join(' · '),
                      key: const ValueKey('overview-peek-place'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                    OverviewUsageLine(sessionId: id),
                  ],
                ),
              ),
              OverviewPinButton(sessionId: id),
              IconButton(
                key: const ValueKey('overview-peek-previous'),
                tooltip: 'Previous session (↑)',
                visualDensity: VisualDensity.compact,
                onPressed: onPrevious,
                icon: const Icon(AppIcons.caretUp),
              ),
              IconButton(
                key: const ValueKey('overview-peek-next'),
                tooltip: 'Next session (↓)',
                visualDensity: VisualDensity.compact,
                onPressed: onNext,
                icon: const Icon(AppIcons.caretDown),
              ),
              IconButton(
                key: const ValueKey('overview-peek-close'),
                tooltip: 'Close peek (Esc)',
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(AppIcons.x),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Padding(
            padding: const EdgeInsets.only(right: Insets.sm),
            child: Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OverviewStatePill(card: card),
                OverviewResumingLabel(sessionId: id),
                if (resumable)
                  FilledButton.tonalIcon(
                    key: const ValueKey('overview-peek-resume'),
                    onPressed: () => resumeFromDashboard(context, ref, entry),
                    icon: const Icon(AppIcons.play),
                    label: const Text('Resume'),
                  ),
                if (live)
                  TextButton.icon(
                    key: const ValueKey('overview-peek-stop'),
                    onPressed: () =>
                        endSessionFromRow(context, ref, id, title: entry.title),
                    icon: const Icon(AppIcons.stop),
                    label: const Text('Stop'),
                  ),
                if (archivable)
                  OverviewArchiveGate(
                    sessionId: id,
                    builder: (resuming) => TextButton.icon(
                      key: const ValueKey('overview-peek-archive'),
                      onPressed: resuming
                          ? null
                          : () => archiveSessionsFromUi(context, ref, [native]),
                      icon: const Icon(AppIcons.tray),
                      label: const Text('Archive'),
                    ),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('overview-peek-open'),
                  onPressed: () => openOverviewSession(context, ref, entry),
                  icon: const Icon(AppIcons.arrowSquareOut),
                  label: const Text('Open tab'),
                ),
              ],
            ),
          ),
          if (plan != null && plan.total > 0) ...[
            const SizedBox(height: Insets.sm),
            Padding(
              padding: const EdgeInsets.only(right: Insets.sm),
              child: OverviewPlanLine(plan: plan),
            ),
          ],
        ],
      ),
    );
  }
}

/// The peek's tabs: the full width beside a board; on a phone a row that
/// scrolls, so no label is ever cut short.
class _PeekTabRow extends StatelessWidget {
  const _PeekTabRow({required this.scrolls, required this.child});

  final bool scrolls;
  final Widget child;

  @override
  Widget build(BuildContext context) => scrolls
      ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: child)
      : SizedBox(width: double.infinity, child: child);
}

/// **The session's own controls in the peek**: the bar's widgets, not
/// copies — the permission, mode and model chips, the operator badge, the
/// delivery step and ⋯ (which holds the operator grant) — so what is set
/// here is what the session's tab shows. In one run that scrolls rather than
/// squeezes, ⋯ pinned outside it, as the bar's narrow row has them.
class OverviewPeekControls extends StatelessWidget {
  const OverviewPeekControls({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('overview-peek-controls'),
    padding: const EdgeInsets.fromLTRB(
      Insets.sm,
      Insets.xxs,
      Insets.xxs,
      Insets.xxs,
    ),
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SessionAgentChip(sessionId: sessionId, maxLabelWidth: 160),
                const SizedBox(width: Insets.xs),
                OperatorChip(sessionId: sessionId, onlyWhenOn: true),
                const SizedBox(width: Insets.xs),
                DeliveryStrip(
                  sessionId: sessionId,
                  hostedOnTerminal: true,
                  compact: true,
                  folded: true,
                ),
              ],
            ),
          ),
        ),
        SessionMoreButton(sessionId: sessionId),
      ],
    ),
  );
}

/// **The peek on a phone**: a slim bar instead of the header. Back, the
/// agent, the title on one line, Resume or Stop and Open tab; under the
/// title the state and one muted line of agent · model · place. Pin, ↑ ↓,
/// the parent, Archive and the usage are in ⋯.
class _PeekBar extends ConsumerWidget {
  const _PeekBar({
    required this.card,
    required this.onClose,
    this.onPeek,
    this.onPrevious,
    this.onNext,
  });

  final OverviewCard card;
  final VoidCallback onClose;
  final ValueChanged<OverviewCard>? onPeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final id = entry.id;
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final agent = watchOverviewAgentName(ref, card);
    final model = ref.watch(sessionActiveModelProvider(id))?.label;
    final place = watchOverviewPlace(ref, card);
    final native = entry.native;
    final live = native != null && sessionHasLiveProcess(ref, id);
    final archivable =
        native != null && !native.isArchived && !sessionIsLive(ref, native);
    final resumable = watchOverviewResumable(ref, card);
    final pinned = ref.watch(
      overviewPrefsProvider.select((p) => p.pinned.contains(id)),
    );
    final parentId = native?.parentSessionId;
    final parent = parentId == null
        ? null
        : overviewCardOf(ref.watch(overviewBoardProvider), parentId);
    Widget action(
      String key,
      String tooltip,
      IconData icon,
      VoidCallback onPressed,
    ) => IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: Icon(icon),
    );
    PopupMenuItem<VoidCallback> item(
      String key,
      String label,
      IconData icon,
      VoidCallback? run,
    ) => PopupMenuItem<VoidCallback>(
      key: ValueKey('overview-peek-menu:$key'),
      value: run,
      enabled: run != null,
      child: Row(
        children: [
          Icon(icon, size: density.iconSmall),
          const SizedBox(width: Insets.sm),
          Flexible(child: Text(label)),
        ],
      ),
    );
    final bar = Row(
      children: [
        action('overview-peek-close', 'Back', AppIcons.arrowLeft, onClose),
        OverviewAgentRing(card: card),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (resumable)
          action(
            'overview-peek-resume',
            'Resume',
            AppIcons.play,
            () => resumeFromDashboard(context, ref, entry),
          )
        else if (live)
          action(
            'overview-peek-stop',
            'Stop',
            AppIcons.stop,
            () => endSessionFromRow(context, ref, id, title: entry.title),
          ),
        action(
          'overview-peek-open',
          'Open tab',
          AppIcons.arrowSquareOut,
          () => openOverviewSession(context, ref, entry),
        ),
        PopupMenuButton<VoidCallback>(
          key: const ValueKey('overview-peek-more'),
          tooltip: 'More',
          icon: const Icon(AppIcons.dotsThreeVertical),
          onSelected: (run) => run(),
          itemBuilder: (_) => [
            item(
              'pin',
              pinned ? 'Unpin' : 'Pin to the top',
              AppIcons.pushPin,
              () => toggleOverviewPin(context, ref, id),
            ),
            item('previous', 'Previous session', AppIcons.caretUp, onPrevious),
            item('next', 'Next session', AppIcons.caretDown, onNext),
            if (parent != null)
              item(
                'parent',
                'Sub-session of ${parent.entry.title}',
                AppIcons.caretUp,
                onPeek == null ? null : () => onPeek!(parent),
              ),
            if (archivable)
              item(
                'archive',
                'Archive',
                AppIcons.tray,
                () => archiveSessionsFromUi(context, ref, [native]),
              ),
            PopupMenuItem<VoidCallback>(
              key: const ValueKey('overview-peek-menu:usage'),
              enabled: false,
              child: OverviewUsageLine(sessionId: id),
            ),
          ],
        ),
      ],
    );
    // The state and one muted line of meta, the full width under the bar: in
    // the title's column a large text's chip pushed the line off the edge.
    return Padding(
      key: const ValueKey('overview-peek-bar'),
      padding: const EdgeInsets.fromLTRB(0, Insets.xxs, Insets.xs, Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          bar,
          Padding(
            padding: const EdgeInsets.only(left: Insets.md),
            child: Row(
              children: [
                OverviewStatePill(card: card),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    [?agent, ?model, if (place.isNotEmpty) place].join(' · '),
                    key: const ValueKey('overview-peek-place'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Counts the peek's chat as on screen while it is up: no workbench group
/// shows it, so the chat gate would otherwise never read a terminal
/// session's transcript.
class _ShownChat extends ConsumerStatefulWidget {
  const _ShownChat({required this.child});

  final Widget child;

  @override
  ConsumerState<_ShownChat> createState() => _ShownChatState();
}

class _ShownChatState extends ConsumerState<_ShownChat> {
  late final ChatsShownOutsideGroups _shown;
  var _counted = false;

  @override
  void initState() {
    super.initState();
    _shown = ref.read(chatsShownOutsideGroupsProvider.notifier);
    // After the frame: a provider is not changed while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shown.add();
      _counted = true;
    });
  }

  @override
  void dispose() {
    if (_counted) {
      final shown = _shown;
      Future.microtask(shown.remove);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The session's own terminal pane, live: what is typed here goes to it.
class _PeekTerminal extends ConsumerWidget {
  const _PeekTerminal({required this.paneId});

  final String paneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) {
      return const PanePlaceholder(
        message: 'This session has no terminal open on this machine.',
        icon: AppIcons.terminal,
      );
    }
    final settings = ref.watch(settingsControllerProvider);
    return KeyedSubtree(
      key: ValueKey('overview-peek-terminal:$paneId'),
      child: LiveTerminalPane(
        paneId: paneId,
        fallback: instance,
        focused: true,
        fontSize: settings.terminalFontSize,
        terminalTheme: terminalThemeFor(
          Theme.of(context),
          ref.watch(terminalPaletteProvider),
        ),
        chordOverrides: settings.terminalChordOverrides,
        onKeyEvent: TerminalActions(ref).onPaneKey,
        onSecondaryTapDown: (_, _) {},
        // A click types here; it does not bring the session's tab forward.
        claimsPaneFocus: false,
        // Its own tab sizes the grid; the peek draws it at that size.
        sizesGrid: false,
      ),
    );
  }
}

/// The files the session changed, each with its +/− and, opened, its diff.
class _PeekFiles extends ConsumerStatefulWidget {
  const _PeekFiles({required this.card, required this.files});

  final OverviewCard card;
  final List<String>? files;

  @override
  ConsumerState<_PeekFiles> createState() => _PeekFilesState();
}

class _PeekFilesState extends ConsumerState<_PeekFiles> {
  String? _open;

  /// The height an opened diff is given inside the list.
  static const _diffHeight = Insets.xxl * 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final files = widget.files;
    if (files == null) {
      return Center(
        child: Text('What this session changed is not known.', style: muted),
      );
    }
    if (files.isEmpty) {
      return Center(
        child: Text('No files changed in this session yet.', style: muted),
      );
    }
    final checkout = widget.card.entry.directory;
    final stats = checkout == null
        ? const <String, FileDiffStat>{}
        : ref.watch(overviewFileStatsProvider(checkout)).value ??
              const <String, FileDiffStat>{};
    final semantic = SemanticColors.of(context);
    return ListView(
      key: const ValueKey('overview-peek-files'),
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      children: [
        for (final path in files) ...[
          () {
            final relative = _relative(path, stats, checkout?.path);
            final stat = stats[relative];
            final name = path
                .split(RegExp(r'[\\/]'))
                .where((p) => p.isNotEmpty)
                .lastOrNull;
            return InkWell(
              key: ValueKey('overview-peek-file:$path'),
              onTap: checkout == null
                  ? null
                  : () => setState(() => _open = _open == path ? null : path),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.md,
                  vertical: Insets.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      _open == path ? AppIcons.caretDown : AppIcons.caretRight,
                      size: UiDensity.of(context).iconSmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Tooltip(
                        message: path,
                        child: Text(
                          name ?? path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                    if (stat != null && !stat.isBinary)
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '+${stat.added}',
                              style: TextStyle(color: semantic.diffAdded),
                            ),
                            const TextSpan(text: ' '),
                            TextSpan(
                              text: '−${stat.removed}',
                              style: TextStyle(color: semantic.diffRemoved),
                            ),
                          ],
                        ),
                        key: ValueKey('overview-peek-file-stat:$path'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
              ),
            );
          }(),
          if (_open == path && checkout != null)
            SizedBox(
              height: _diffHeight,
              child: FileDiffView(
                key: ValueKey('overview-peek-diff:$path'),
                path: _relative(path, stats, checkout.path),
                checkout: checkout,
                repositoryId: widget.card.entry.native?.repositoryId,
              ),
            ),
        ],
      ],
    );
  }

  /// [path] as the checkout's own git spells it: a key of [stats] it ends
  /// with, else [path] with the checkout's prefix taken off.
  static String _relative(
    String path,
    Map<String, FileDiffStat> stats,
    String? checkout,
  ) {
    final slashed = path.replaceAll(r'\', '/');
    for (final key in stats.keys) {
      if (slashed == key || slashed.endsWith('/$key')) return key;
    }
    final root = checkout?.replaceAll(r'\', '/');
    if (root != null && slashed.startsWith('$root/')) {
      return slashed.substring(root.length + 1);
    }
    return slashed;
  }
}

class _PeekSubSession extends ConsumerWidget {
  const _PeekSubSession({required this.card, this.onTap});

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final line = watchOverviewLine(ref, card);
    return Column(
      key: ValueKey('overview-peek-sub:${card.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewSubSessionRow(card: card, onOpen: (c) => onTap?.call(c)),
        Padding(
          padding: const EdgeInsets.only(
            left: Insets.lg + Insets.xs,
            bottom: Insets.xs,
          ),
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens [entry] where the session lists would — resuming one that ended —
/// and raises the workbench on the phone.
Future<void> openOverviewSession(
  BuildContext context,
  WidgetRef ref,
  WorkspaceSessionEntry entry,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final actions = ref.read(explorerActionsProvider);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final native = entry.native;
  final imported = entry.imported;
  final ExplorerResult? result;
  if (native != null) {
    result = await actions.openNative(native.id);
  } else if (imported != null) {
    result = await actions.openImported(imported);
  } else {
    focusWatchedSession(ref.container, openId: entry.id, imported: false);
    result = null;
  }
  if (!(result?.isFailure ?? false)) showWorkbench?.call();
  final message = result?.message;
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
