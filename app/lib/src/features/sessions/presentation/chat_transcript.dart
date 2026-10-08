import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import 'package:karmashala_ui/dialogs.dart' show showConfirmDialog;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart'
    show DesktopMenuDetailItem, DesktopMenuItem;
import '../../../app/widgets/row_menu_sheet.dart';
import '../../agents/presentation/agent_logo.dart';
import '../application/turn_fork_points.dart';
import '../application/turn_rewinds.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/panes.dart' show StatusDot;
import 'package:karmashala_ui/charts.dart' show formatCompactCount;
import 'package:karmashala_ui/rows.dart'
    show compactAge, formatElapsed, kActivityTickInterval;
import 'package:agent_cli/descriptors.dart' show AgentPlan;
import 'package:agent_cli/read.dart'
    show
        RewindMarker,
        kTranscriptNoticeRole,
        kTranscriptRewindRole,
        rewindFolds,
        taskNotificationLine;
import 'package:agent_cli/stream.dart';
import 'package:karmashala_automations/automations.dart'
    show AutomationAttribution;
import 'package:karmashala_session/session.dart' show splitScratchPreamble;
import '../../automations/presentation/automation_sent_label.dart';
import 'package:karmashala_ui/transcript.dart';
import 'chat_cards/plan_update_card.dart';
import 'tool_activity_row.dart';
import 'tool_edit_diff_card.dart';
import 'tool_run.dart';
import 'transcript_image_preview.dart';
import 'transcript_inline_images.dart';
import 'turn_changed_files.dart';

export 'tool_run.dart' show TranscriptTurn;
export '../application/turn_fork_points.dart'
    show TranscriptTurnStart, TurnForkPoints, TurnForkTarget, turnForkPoints;
export '../application/turn_rewinds.dart' show TurnRewindTarget;

part 'chat_transcript/agent_switch_rows.dart';
part 'chat_transcript/chat_message.dart';
part 'chat_transcript/command_time.dart';
part 'chat_transcript/message_cards.dart';
part 'chat_transcript/message_rows.dart';
part 'chat_transcript/prose_roles.dart';
part 'chat_transcript/rewind_fold.dart';
part 'chat_transcript/tool_batch.dart';
part 'chat_transcript/tool_message_card.dart';
part 'chat_transcript/turn_footer.dart';
part 'chat_transcript/turn_actions.dart';
part 'chat_transcript/turn_meta.dart';
part 'chat_transcript/transcript_notes.dart';
part 'chat_transcript/transcript_text.dart';
part 'chat_transcript/turn_memo.dart';
part 'chat_transcript/view_chrome.dart';

/// The most of [ChatTranscriptView]'s height its footer may take; the rest is
/// the conversation's. A footer with no ceiling pushed the list off the pane.
const double kTranscriptFooterShare = 0.7;

/// Called when the user keeps a message as a note: the message, and its index
/// in the whole transcript — not the visible window — which the note records.
typedef SaveNoteCallback = void Function(ChatMessage message, int ordinal);

/// An extra widget to hang under one message's body. A builder rather than a
/// field on [ChatMessage], which the remote payloads carry and have no widgets.
typedef MessageDetailBuilder =
    Widget? Function(ChatMessage message, int ordinal);

/// A CLI-style conversation list. Long transcripts start anchored at the newest
/// message and load earlier turns on demand.
class ChatTranscriptView extends StatefulWidget {
  const ChatTranscriptView({
    required this.messages,
    this.footer,
    this.trailing,
    this.workingLine,
    this.lastTurnVerb,
    this.lastTurnTokens,
    this.lastTurnStoppedAt,
    this.emptyHint = 'No messages yet.',
    this.onSaveNote,
    this.resolveHostPath,
    this.onPathTap,
    this.onLinkTap,
    this.detailBuilder,
    this.turn = TranscriptTurn.unknown,
    this.earlier = 0,
    this.onLoadEarlier,
    this.firstOrdinal = 0,
    this.agentId,
    this.emptyBuilder,
    this.toLatest,
    this.filePreviewBuilder,
    this.seenUntil,
    this.now,
    this.turnActions,
    this.sentencePerLine = false,
    super.key,
  });

  final List<ChatMessage> messages;

  /// Starts each sentence of the agent's prose on a line of its own.
  final bool sentencePerLine;

  /// Retry, Edit and resend and Fork from here on each turn; null offers
  /// none of them.
  final TranscriptTurnActions? turnActions;

  /// What a running command's time counts up to; null is the wall clock.
  final DateTime Function()? now;

  /// When the reader last looked: the messages after it sit under a "New
  /// since you last looked" line, with all but a few before it folded. Null
  /// draws neither.
  final DateTime? seenUntil;

  /// Each notification takes the list to its newest message, as *Jump to
  /// latest* does — where an open ask hangs.
  final Listenable? toLatest;

  /// Builds the preview a tapped file path opens under its message, handed
  /// the path as written and how to close it. Null sends taps to
  /// [onPathTap] instead.
  final Widget Function(String token, VoidCallback onClose)? filePreviewBuilder;

  /// What to show in place of the standard empty state, which it is handed.
  final Widget Function(Widget standard)? emptyBuilder;

  /// The agent this conversation is with, when known: the empty state wears
  /// its mark rather than a generic glyph.
  final String? agentId;

  /// Messages before [messages] that are not held here but can be asked
  /// for with [onLoadEarlier] — a server-read transcript arrives a page at a
  /// time. Offered once every held message is shown.
  final int earlier;
  final VoidCallback? onLoadEarlier;

  /// The first message's place in the whole conversation, so a row keeps its
  /// key (and its open state) when [onLoadEarlier] puts older ones above it.
  final int firstOrdinal;
  final Widget? footer;

  /// Scrolls with the conversation, after its last row.
  final Widget? trailing;

  /// The live line under the last message while [turn] is working — outside
  /// the scroll, so it and its Stop stay in sight as the terminal's spinner
  /// does. Null draws none.
  final Widget? workingLine;

  /// The latest finished turn's own past-tense word ("Crunched") and tokens,
  /// for its footer; null where the agent left none.
  final String? lastTurnVerb;
  final int? lastTurnTokens;

  /// When Stop was pressed in the last turn, once it has ended: that turn's
  /// footer reads "Stopped". Null when it was not stopped from here.
  final DateTime? lastTurnStoppedAt;
  final String emptyHint;

  /// Turns a path an agent wrote into one this process can open — a WSL
  /// `/mnt/c/…` into its Windows form. Omitted means they are already host paths.
  final String? Function(String path)? resolveHostPath;

  /// Where a file path a reader clicked goes — see [MarkdownMessage.onPathTap].
  /// Null leaves every path as plain text.
  final PathLinkCallback? onPathTap;

  /// Where a link the agent or the user wrote goes. Null leaves links inert.
  final ValueChanged<String>? onLinkTap;

  /// Keeps a message as a note. Null hides the affordance entirely — the view
  /// knows nothing about the Notes feature, only where it may send one.
  final SaveNoteCallback? onSaveNote;

  /// What, if anything, hangs under a given row — see [MessageDetailBuilder].
  final MessageDetailBuilder? detailBuilder;

  /// Where the session's turn stands: whether the trailing run of tool calls
  /// is drawn live, as the call in progress, or settled.
  final TranscriptTurn turn;

  /// Builds of a message row, counted so a cost test can prove a new or
  /// streaming message redraws itself and not the rows above it.
  @visibleForTesting
  static int debugMessageBuildCount = 0;

  @override
  State<ChatTranscriptView> createState() => _ChatTranscriptViewState();
}

class _ChatTranscriptViewState extends State<ChatTranscriptView>
    with _TranscriptTurnMemo {
  static const _page = 40;
  final _scroll = ScrollController();
  int _shown = _page;

  /// Whether the reader is at the newest message. While it holds, the list is
  /// kept at its end by [_onMetrics] whatever moves that end.
  bool _stickToBottom = true;

  /// Whether the list was on screen at the last build — see [_followVisibility].
  bool _visible = true;

  /// Touch only: the turn whose actions a tap has shown.
  final _tappedTurn = ValueNotifier<Object?>(null);

  DateTime _clockNow() => (widget.now ?? DateTime.now)();

  late final _commandClock = _CommandClock(_clockNow());

  /// The one timer every running command's time ticks on, armed only while
  /// one runs and the list is on screen.
  Timer? _commandTick;

  void _followRunningCommands(List<ChatMessage> visible, bool onScreen) {
    final running =
        onScreen &&
        widget.turn != TranscriptTurn.idle &&
        visible.any((m) => m.pending && m.at != null && isCommandCall(m));
    if (!running) {
      _commandTick?.cancel();
      _commandTick = null;
      return;
    }
    _commandClock.quietly = _clockNow();
    _commandTick ??= Timer.periodic(
      kActivityTickInterval,
      (_) => _commandClock.tick(_clockNow()),
    );
  }

  /// Whether the reader has left the newest message: *Jump to latest* shows.
  bool _awayFromLatest = false;

  /// Messages kept in sight above the "new since" line before the fold.
  static const _keptBeforeNew = 3;

  /// The first message written after [ChatTranscriptView.seenUntil], or null
  /// when there is none, or nothing older to set it apart from.
  int? _firstNew() {
    final seen = widget.seenUntil;
    if (seen == null) return null;
    final messages = widget.messages;
    for (var i = 0; i < messages.length; i++) {
      final at = messages[i].at;
      if (at != null && at.isAfter(seen)) return i == 0 ? null : i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Older turns fold behind "Load earlier", the new ones and a few before
    // them in sight.
    if (_firstNew() case final first?) {
      _shown = widget.messages.length - math.max(0, first - _keptBeforeNew);
    }
    _scroll.addListener(_onScroll);
    FocusManager.instance.addListener(_revealFocused);
    widget.toLatest?.addListener(_toLatest);
  }

  @override
  void didUpdateWidget(ChatTranscriptView old) {
    super.didUpdateWidget(old);
    if (!identical(old.toLatest, widget.toLatest)) {
      old.toLatest?.removeListener(_toLatest);
      widget.toLatest?.addListener(_toLatest);
    }
  }

  @override
  void dispose() {
    widget.toLatest?.removeListener(_toLatest);
    FocusManager.instance.removeListener(_revealFocused);
    _scroll.dispose();
    _tappedTurn.dispose();
    _commandTick?.cancel();
    _commandClock.dispose();
    super.dispose();
  }

  /// Shows the whole of a row the keyboard focused. Traversal only keeps the
  /// edge it moves towards in view, so Tab into a list pinned to its newest
  /// message landed on the topmost row — scrolled out above, and left there,
  /// focused and unseen.
  void _revealFocused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (!mounted || context == null || !_scroll.hasClients) return;
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    if (context.findAncestorStateOfType<_ChatTranscriptViewState>() != this) {
      return;
    }
    if (context.findRenderObject()?.attached != true) return;
    // The far edge first, then the near one: a row taller than the view
    // shows its start.
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    ]) {
      Scrollable.ensureVisible(context, alignmentPolicy: policy);
    }
    // A reveal a few pixels short of the end still leaves it: the slack
    // [_onScroll] allows a reader would have the row pinned straight back out.
    final pos = _scroll.position;
    _stickToBottom = pos.pixels >= pos.maxScrollExtent;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _stickToBottom = pos.pixels >= pos.maxScrollExtent - 24;
    if (_awayFromLatest == _stickToBottom) {
      setState(() => _awayFromLatest = !_stickToBottom);
    }
    if (pos.pixels - pos.minScrollExtent > 80) return;
    if (_shown < widget.messages.length) {
      _showMoreHeld();
    } else if (_canLoadEarlier) {
      _anchorAtFirstRow();
      widget.onLoadEarlier!();
    }
  }

  /// The file each message has open under it, by its ordinal in the whole
  /// conversation; one per message, the latest tapped.
  final _previews = <int, String>{};

  void _openPreview(int ordinal, String token) =>
      setState(() => _previews[widget.firstOrdinal + ordinal] = token);

  void _closePreview(int ordinal) =>
      setState(() => _previews.remove(widget.firstOrdinal + ordinal));

  String _turnTextAt(int ordinal) =>
      transcriptTurnMarkdown(widget.messages, ordinal);

  void _showMoreHeld() {
    _anchorAtFirstRow();
    setState(() => _shown = math.min(_shown + _page, widget.messages.length));
  }

  /// The ordinal of the first row the list grows down from. Older rows go
  /// above it, growing up, so loading them never moves what the reader sees.
  /// Null until something older is loaded: until then the list is a plain one.
  int? _anchorOrdinal;
  final _centerKey = GlobalKey(debugLabel: 'chat-center');
  final _leadKey = GlobalKey(debugLabel: 'chat-lead');

  /// Moves the list's origin to its first row, keeping every row where it is
  /// on screen. A list shorter than its view stays plain: nothing moves there.
  void _anchorAtFirstRow() {
    if (_anchorOrdinal != null || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent <= 0 || widget.messages.isEmpty) return;
    final lead = _leadKey.currentContext?.findRenderObject();
    final leadHeight = lead is RenderBox && lead.hasSize ? lead.size.height : 0;
    final start = math.max(0, widget.messages.length - _shown);
    _anchorOrdinal = widget.firstOrdinal + start;
    pos.correctPixels(pos.pixels - (Insets.xl + leadHeight));
    setState(() {});
  }

  bool get _canLoadEarlier =>
      widget.earlier > 0 && widget.onLoadEarlier != null;

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  void _toLatest() {
    _stickToBottom = true;
    _jumpToBottom();
  }

  /// Keeps a pinned list at its end after every layout that moves the end
  /// without scrolling: a lazy list's estimate settling as the last rows are
  /// built, a page arriving, a row growing (an image, markdown, a turn's
  /// meta), or the viewport shrinking under the recap or the keyboard. A
  /// single jump on open landed on the first estimate, short of the newest.
  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0 || !_stickToBottom) return false;
    final pos = _scroll.hasClients ? _scroll.position : null;
    // Never under a finger or a fling, nor while any scroll is moving — a
    // selection dragged past the top edge scrolls the list a step at a time,
    // and each step built rows that re-measured the end: the reader is
    // leaving the bottom.
    if (pos == null ||
        pos.userScrollDirection != ScrollDirection.idle ||
        pos.isScrollingNotifier.value) {
      return false;
    }
    if (pos.pixels < pos.maxScrollExtent) _jumpToBottom();
    return false;
  }

  /// Coming back on screen — Chat after Terminal, or the phone's group in
  /// front again — lands on the newest message.
  void _followVisibility(bool visible) {
    if (visible && !_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toLatest();
      });
    }
    _visible = visible;
  }

  Widget _emptyState() {
    final standard = _ChatEmptyState(
      hint: widget.emptyHint,
      agentId: widget.agentId,
    );
    return widget.emptyBuilder?.call(standard) ?? standard;
  }

  @override
  Widget build(BuildContext context) {
    final onScreen = Visibility.of(context);
    _followVisibility(onScreen);
    final total = widget.messages.length;
    final start = math.max(0, total - _shown);
    final visible = widget.messages.sublist(start);
    _followRunningCommands(visible, onScreen);
    // Only the loaded window: the window is a suffix, so its trailing run is
    // the transcript's, and a tick costs the window rather than the whole list.
    final rows = transcriptRows(visible, turn: widget.turn);
    final lead = start > 0 || _canLoadEarlier ? 1 : 0;
    // Rows are keyed by their ordinal in the whole transcript, so loading an
    // older page shifts indices without handing one row's element to another.
    // A live run has its own key, so its open state never outlives the turn.
    final base = widget.firstOrdinal + start;
    Key keyOf(TranscriptRow row) => row.live
        ? ValueKey<String>('${base + row.from}:live')
        : ValueKey<int>(base + row.from);
    final indexOfKey = <Key, int>{
      for (var i = 0; i < rows.length; i++) keyOf(rows[i]): i,
    };
    // Rows before the anchor grow up from it; a transcript replaced under the
    // view with nothing past the anchor falls back to a plain list.
    var split = 0;
    if (_anchorOrdinal case final anchor?) {
      split = rows.indexWhere((row) => base + row.from >= anchor);
      if (split <= 0) {
        if (split < 0) _anchorOrdinal = null;
        split = 0;
      }
    }

    // The row the "new since you last looked" line sits above, if in view.
    final firstNew = _firstNew();
    final newRow = firstNew == null || firstNew < start
        ? -1
        : rows.indexWhere((row) => start + row.to > firstNew);

    // Each plan's predecessor among the held messages, so an update can say
    // what it changed.
    final planBefore = previousPlans(widget.messages);

    // Each finished turn's footer; the agent's word and tokens are known only
    // for the latest, and only while no turn has opened after it.
    final footers = _footersFor(widget.messages, widget.turn);
    final latest = footers.isEmpty ? null : footers.keys.reduce(math.max);
    final latestIsLast =
        latest != null && !widget.messages.skip(latest + 1).any(_opensTurn);
    final prose = _proseFor(widget.messages, widget.turn);

    // Keyed at the top: the list finds a row by its item's own key.
    Widget rowAt(int offset) {
      final ordinal = start + offset;
      Widget row = _MessageRow(
        message: visible[offset],
        previousPlan: planBefore[ordinal],
        ordinal: ordinal,
        turnText: _turnTextAt,
        preview: _previews[widget.firstOrdinal + ordinal],
        onPreview: widget.filePreviewBuilder == null ? null : _openPreview,
        onClosePreview: _closePreview,
        previewBuilder: widget.filePreviewBuilder,
        onSaveNote: widget.onSaveNote,
        resolveHostPath: widget.resolveHostPath,
        onPathTap: widget.onPathTap,
        onLinkTap: widget.onLinkTap,
        detailBuilder: widget.detailBuilder,
        turnActions: widget.turnActions,
        place: widget.turnActions == null ? null : _placeOf(ordinal),
        prose: prose[ordinal],
        sentencePerLine: widget.sentencePerLine,
      );
      if (footers[ordinal] case final footer?) {
        final own = latestIsLast && ordinal == latest;
        row = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            row,
            _TurnFooterLine(
              footer: footer,
              verb: own ? widget.lastTurnVerb : null,
              tokens: own ? widget.lastTurnTokens : null,
            ),
          ],
        );
      }
      return _TappedTurn(
        key: ValueKey<int>(base + offset),
        notifier: _tappedTurn,
        child: row,
      );
    }

    _readFolds();

    Widget plain(int index, TranscriptRow row) {
      final drawn = !row.isBatch
          ? rowAt(row.from)
          : _ToolBatchTile(
              key: keyOf(row),
              messages: visible,
              row: row,
              rowAt: rowAt,
              resolveHostPath: widget.resolveHostPath,
            );
      if (index != newRow) return drawn;
      return Column(
        key: keyOf(row),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const _NewSinceLine(), drawn],
      );
    }

    // A rewound row: hidden under its fold's header, which the first of
    // them in the window carries; dimmed when the fold is open.
    Widget folded(int index, TranscriptRow row, int owner) {
      final first = math.max(_foldStarts[owner] ?? owner, start);
      final header = start + row.from <= first && first < start + row.to
          ? _RewoundFoldHeader(
              marker: RewindMarker.parse(widget.messages[owner].text),
              open: _openFolds.contains(widget.firstOrdinal + owner),
              onToggle: () => _toggleFold(owner),
            )
          : null;
      if (!_openFolds.contains(widget.firstOrdinal + owner)) {
        return header == null
            ? SizedBox.shrink(key: keyOf(row))
            : KeyedSubtree(key: keyOf(row), child: header);
      }
      return Column(
        key: keyOf(row),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?header,
          Opacity(
            opacity: StateLayers.rewoundOpacity,
            child: plain(index, row),
          ),
        ],
      );
    }

    Widget item(int index) {
      final row = rows[index];
      // A rewind's own row draws nothing: its fold's header says it.
      if (visible[row.from].role == kTranscriptRewindRole) {
        return SizedBox.shrink(key: keyOf(row));
      }
      final owner = _folds[start + row.from];
      if (owner != null) return folded(index, row, owner);
      return plain(index, row);
    }

    Widget list(double gutter) {
      final pad = EdgeInsets.symmetric(horizontal: gutter);
      final more = start > 0 ? start : widget.earlier;
      final slivers = <Widget>[
        const SliverToBoxAdapter(child: SizedBox(height: Insets.xl)),
        if (lead == 1)
          SliverToBoxAdapter(
            // Held here first; then, from the server, the ones before those.
            child: SelectionContainer.disabled(
              key: _leadKey,
              child: Center(
                child: TextButton.icon(
                  onPressed: start > 0
                      ? _showMoreHeld
                      : () {
                          _anchorAtFirstRow();
                          widget.onLoadEarlier?.call();
                        },
                  icon: const Icon(AppIcons.caretUp),
                  label: Text(
                    'Load $more earlier message${more == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: pad,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => item(split - 1 - i),
              childCount: split,
              findChildIndexCallback: (key) {
                final at = indexOfKey[key];
                return at == null || at >= split ? null : split - 1 - at;
              },
            ),
          ),
        ),
        SliverPadding(
          key: _centerKey,
          padding: pad,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => item(split + i),
              childCount: rows.length - split,
              findChildIndexCallback: (key) {
                final at = indexOfKey[key];
                return at == null || at < split ? null : at - split;
              },
            ),
          ),
        ),
        if (widget.trailing case final trailing?)
          SliverPadding(
            padding: pad,
            sliver: SliverToBoxAdapter(child: trailing),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: Insets.xl)),
      ];
      return CustomScrollView(
        key: const ValueKey('chat-transcript-list'),
        controller: _scroll,
        center: _anchorOrdinal == null ? null : _centerKey,
        slivers: slivers,
      );
    }

    // The conversation sits on the terminal's tone (board N2), so switching a
    // pane between its two views changes what is drawn, not the room it is in.
    return ColoredBox(
      color: SurfaceTones.of(context).term,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gutter = chatGutterFor(constraints.maxWidth);
          return Column(
            children: [
              // Its own traversal group so its stops cannot interleave with the
              // footer's: tabbing below the fold scrolls the list under the policy.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, room) => ChatViewportRoom(
                    height: room.maxHeight,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: FocusTraversalGroup(
                            child: total == 0
                                ? _emptyState()
                                : Align(
                                    alignment: Alignment.topCenter,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: Chrome.chatWidth,
                                      ),
                                      child: _TranscriptNow(
                                        now: DateTime.now(),
                                        // One selection over every built row: a drag runs
                                        // from one message into the next.
                                        child: _CommandClockScope(
                                          clock: _commandClock,
                                          child: TranscriptSelectionArea(
                                            child:
                                                NotificationListener<
                                                  ScrollMetricsNotification
                                                >(
                                                  onNotification: _onMetrics,
                                                  // The pane's whole width (owner, 2026-09-28),
                                                  // with a gutter so no word touches its edge.
                                                  child: list(gutter),
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        // A round arrow floating at the list's bottom right, the
                        // way chat apps offer it: a full-width row above the
                        // footer cost a line of the conversation and moved the
                        // composer every time it came and went (owner,
                        // 2026-10-01).
                        if (_awayFromLatest && total > 0)
                          PositionedDirectional(
                            end: Insets.md,
                            bottom: Insets.md,
                            child: FloatingActionButton.small(
                              // Several transcripts can be mounted at once; a
                              // shared hero tag would collide between them.
                              heroTag: null,
                              tooltip: 'Jump to latest',
                              onPressed: _toLatest,
                              child: const Icon(
                                AppIcons.arrowDown,
                                semanticLabel: 'Jump to latest',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.workingLine case final line?
                  when widget.turn == TranscriptTurn.working)
                Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: Chrome.chatWidth,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: gutter),
                      child: line,
                    ),
                  ),
                ),
              if (widget.footer != null)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * kTranscriptFooterShare,
                  ),
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: Chrome.chatWidth,
                      ),
                      // The same gutter as the messages: the activity line and
                      // the composer's left edge line up with the words above.
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: gutter),
                        child: widget.footer!,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
