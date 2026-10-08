import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import '../../agents/presentation/agent_logo.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/charts.dart' show formatCompactCount;
import 'package:karmashala_ui/rows.dart' show compactAge, formatElapsed;
import 'package:agent_cli/descriptors.dart' show AgentPlan;
import 'package:agent_cli/read.dart'
    show kTranscriptNoticeRole, taskNotificationLine;
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
import 'turn_changed_files.dart';

export 'tool_run.dart' show TranscriptTurn;

part 'chat_transcript/agent_switch_rows.dart';
part 'chat_transcript/message_rows.dart';
part 'chat_transcript/tool_batch.dart';
part 'chat_transcript/turn_footer.dart';
part 'chat_transcript/turn_meta.dart';

/// The row the transcript view writes itself, saying a compaction happened
/// here. Its own role, because an unknown role is read as the agent's.
const String kCompactionNoticeRole = 'compaction';

/// The row a switched session's transcript holds where another agent took
/// over: drawn as a divider whose text is what that agent was handed.
const String kAgentSwitchNoticeRole = 'agentSwitch';

/// A normalized chat message for the transcript view, independent of whether it
/// came from a native session's event log or an imported CLI transcript.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.tool,
    this.thinking,
    this.at,
    this.pending = false,
    this.pendingToolUseId,
    this.agentName,
    this.agentId,
    this.detail,
    this.queued = false,
    this.images = const [],
    this.model,
  });

  /// `user`, `agent`, `tool`, or `error`.
  final String role;
  final String text;

  /// The structured call behind a `tool` row, when the source carried one. Null
  /// for a tool line we only have prose for; those render exactly as before.
  final ToolActivity? tool;

  final String? thinking;

  /// When the message was written.
  final DateTime? at;

  /// A tool call the source says is unanswered. Not `tool.output == null`: a
  /// call answered with nothing has no output either.
  final bool pending;

  /// The unanswered call's id, when the source named it: what an ask about
  /// this call is matched by.
  final String? pendingToolUseId;

  /// The agent that spoke, named on the first agent row of a turn and on a
  /// switch divider in a session that switched agent; null everywhere else.
  final String? agentName;
  final String? agentId;

  /// Text folded under a notice until it is opened: what a compaction kept.
  final String? detail;

  /// A `user` row the person sent while the agent was still working.
  final bool queued;

  /// Images the person pasted into a `user` row, as paths on the session's
  /// machine.
  final List<String> images;

  /// The label of the model that wrote this agent turn, set only where it
  /// differs from the turn before (and on the first); null everywhere else.
  final String? model;

  /// By value: a live transcript is re-parsed whole on every poll, and an equal
  /// message is what lets its row skip the rebuild.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          other.role == role &&
          other.at == at &&
          other.pending == pending &&
          other.pendingToolUseId == pendingToolUseId &&
          other.agentName == agentName &&
          other.agentId == agentId &&
          other.thinking == thinking &&
          other.detail == detail &&
          other.queued == queued &&
          other.model == model &&
          _samePaths(other.images, images) &&
          _sameTool(other.tool, tool) &&
          other.text == text;

  @override
  int get hashCode => Object.hash(role, text, thinking, at, tool?.name);
}

bool _samePaths(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [ToolActivity] has no equality of its own; these are every field it draws.
bool _sameTool(ToolActivity? a, ToolActivity? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.name == b.name &&
      a.subject == b.subject &&
      a.imagePath == b.imagePath &&
      a.output == b.output &&
      a.outputTruncated == b.outputTruncated &&
      a.isError == b.isError &&
      a.plan == b.plan &&
      a.kind == b.kind &&
      a.editsTruncated == b.editsTruncated &&
      _sameEdits(a.edits, b.edits);
}

bool _sameEdits(List<FileEditRecord> a, List<FileEditRecord> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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
    super.key,
  });

  final List<ChatMessage> messages;

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

class _ChatTranscriptViewState extends State<ChatTranscriptView> {
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

  /// Whether the reader has left the newest message: *Jump to latest* shows.
  bool _awayFromLatest = false;

  List<ChatMessage>? _footerMessages;
  TranscriptTurn? _footerTurn;
  var _footers = const <int, TurnFooter>{};

  /// [turnFooters], walked again only when the list or the turn moved: an
  /// elapsed tick or a hover rebuild costs nothing here.
  Map<int, TurnFooter> _footersFor(
    List<ChatMessage> messages,
    TranscriptTurn turn,
  ) {
    if (identical(messages, _footerMessages) && turn == _footerTurn) {
      return _footers;
    }
    _footerMessages = messages;
    _footerTurn = turn;
    return _footers = turnFooters(
      messages,
      lastTurnOver: turn == TranscriptTurn.idle,
    );
  }

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
      transcriptTurnText(widget.messages, ordinal);

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
    _followVisibility(Visibility.of(context));
    final total = widget.messages.length;
    final start = math.max(0, total - _shown);
    final visible = widget.messages.sublist(start);
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

    Widget item(int index) {
      final row = rows[index];
      final drawn = !row.isBatch
          ? rowAt(row.from)
          : _ToolBatchTile(
              key: keyOf(row),
              messages: visible,
              row: row,
              rowAt: rowAt,
            );
      if (index != newRow) return drawn;
      return Column(
        key: keyOf(row),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const _NewSinceLine(), drawn],
      );
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

/// "New since you last looked", a rule either side.
class _NewSinceLine extends StatelessWidget {
  const _NewSinceLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final rule = Expanded(
      child: Divider(
        color: accent.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
      ),
    );
    return SelectionContainer.disabled(
      child: Padding(
        key: const ValueKey('chat-new-since'),
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        child: Row(
          children: [
            rule,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Text(
                'New since you last looked',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            rule,
          ],
        ),
      ),
    );
  }
}

/// The height the conversation's list is drawn in: the room above the
/// composer, which a card under a call keeps to so its answers stay in sight.
class ChatViewportRoom extends InheritedWidget {
  const ChatViewportRoom({
    required this.height,
    required super.child,
    super.key,
  });

  final double height;

  /// The room, or null outside a transcript.
  static double? of(BuildContext context) {
    final height = context
        .dependOnInheritedWidgetOfExactType<ChatViewportRoom>()
        ?.height;
    return height == null || !height.isFinite ? null : height;
  }

  @override
  bool updateShouldNotify(ChatViewportRoom oldWidget) =>
      height != oldWidget.height;
}

/// Touch only: which turn's actions a tap has shown. One at a time, so a
/// tap on another turn moves them there.
class _TappedTurn extends InheritedWidget {
  const _TappedTurn({required this.notifier, required super.child, super.key});

  final ValueNotifier<Object?> notifier;

  static ValueNotifier<Object?>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_TappedTurn>()?.notifier;

  @override
  bool updateShouldNotify(_TappedTurn oldWidget) =>
      oldWidget.notifier != notifier;
}

/// A message as plain text: what "Show raw" shows and "Copy turn" copies.
String rawMessageText(ChatMessage message) {
  final tool = message.tool;
  if (tool == null) return message.text;
  return [
    toolDisplayName(tool.name),
    if (tool.subject case final subject? when subject.isNotEmpty) subject,
    if (tool.output case final output? when output.isNotEmpty) output,
  ].join('\n');
}

/// The turn holding [index] as text: from the person's message that opened it
/// to the last row before their next one.
String transcriptTurnText(List<ChatMessage> messages, int index) {
  var start = index;
  while (start > 0 && messages[start].role != 'user') {
    start--;
  }
  var end = index + 1;
  while (end < messages.length && messages[end].role != 'user') {
    end++;
  }
  final parts = <String>[];
  for (var i = start; i < end; i++) {
    final message = messages[i];
    switch (message.role) {
      case 'user':
        parts.add('You:\n${splitScratchPreamble(message.text).rest}');
      case 'agent':
        final (_, clean) = splitThinking(
          message.text,
          explicit: message.thinking,
        );
        if (clean.trim().isNotEmpty) parts.add(clean.trim());
      default:
        parts.add('› ${rawMessageText(message)}');
    }
  }
  return parts.join('\n\n');
}

/// The plan each plan row replaced, by index into [messages]; a first plan
/// has no entry.
Map<int, AgentPlan> previousPlans(List<ChatMessage> messages) {
  final before = <int, AgentPlan>{};
  AgentPlan? last;
  for (var i = 0; i < messages.length; i++) {
    final plan = messages[i].tool?.plan;
    if (plan == null) continue;
    if (last != null) before[i] = last;
    last = plan;
  }
  return before;
}

/// The side gutter of the chat column at [width]: the board's 24px where the
/// pane has room for it, and less in a side-panel-narrow pane, where 48px of
/// the 240 would be a fifth of the conversation.
double chatGutterFor(double width) => width < 480 ? Insets.md : Insets.xl;

/// `mcp__server__tool` as `server · tool`; any other name as it came.
String toolDisplayName(String name) {
  if (!name.startsWith('mcp__')) return name;
  final rest = name.substring('mcp__'.length);
  final split = rest.indexOf('__');
  if (split <= 0 || split + 2 >= rest.length) return name;
  return '${rest.substring(0, split)} · ${rest.substring(split + 2)}';
}

/// Selects an appropriate category glyph for a tool name.
IconData _toolIcon(String? name) {
  final lower = name?.toLowerCase() ?? '';
  if (lower.contains('bash') ||
      lower.contains('exec') ||
      lower.contains('cmd') ||
      lower.contains('terminal')) {
    return AppIcons.terminal;
  }
  if (lower.contains('read') ||
      lower.contains('file') ||
      lower.contains('edit') ||
      lower.contains('write') ||
      lower.contains('code')) {
    return AppIcons.code;
  }
  if (lower.contains('search') ||
      lower.contains('grep') ||
      lower.contains('find')) {
    return AppIcons.magnifyingGlass;
  }
  if (lower.contains('image') ||
      lower.contains('photo') ||
      lower.contains('preview')) {
    return AppIcons.image;
  }
  return AppIcons.gearSix;
}

/// What the conversation says when it has nothing to say yet. The four prompt
/// cards that sat here overflowed their row at phone width and are gone.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.hint, this.agentId});

  final String hint;
  final String? agentId;

  /// Centred while it fits, scrollable the moment it does not. `minHeight` is
  /// what keeps the centring: a scroll view hands its child unbounded height.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // A session whose agent keeps no readable transcript is not an empty
    // conversation but a surface that will never have one.
    final isTerminalNotice =
        hint.contains('terminal is the session') ||
        hint.contains('no chat view') ||
        hint.contains('keeps no transcript');

    return Center(
      child: ConstrainedBox(
        // One measure for both branches: they had 520 and 580, a difference no
        // reader can see and two numbers a maintainer has to keep in step.
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // `Chrome.iconHero` is the token for exactly this glyph; the
              // bordered circle each branch invented was chrome around it.
              if (isTerminalNotice)
                Icon(
                  AppIcons.terminal,
                  size: Chrome.iconHero,
                  color: scheme.onSurfaceVariant,
                )
              else if (agentId case final agentId?)
                AgentLogo(
                  agentId: agentId,
                  size: Chrome.iconHero,
                  color: scheme.primary,
                )
              else
                Icon(
                  AppIcons.robot,
                  size: Chrome.iconHero,
                  color: scheme.primary,
                ),
              const SizedBox(height: Insets.sm),
              if (!isTerminalNotice) ...[
                Text(
                  'Ready to assist',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Insets.xs),
              ],
              Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
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

/// The instant every age in one build of the list is measured from. Only the
/// age labels depend on it, so a poll re-ages them without rebuilding a row.
class _TranscriptNow extends InheritedWidget {
  const _TranscriptNow({required this.now, required super.child});

  final DateTime now;

  static DateTime of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TranscriptNow>()?.now ??
      DateTime.now();

  @override
  bool updateShouldNotify(_TranscriptNow oldWidget) => oldWidget.now != now;
}
