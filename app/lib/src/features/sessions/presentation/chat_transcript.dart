import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:agent_cli/stream.dart';
import 'package:karmashala_ui/transcript.dart';
import 'tool_activity_row.dart';
import 'tool_run.dart';

export 'tool_run.dart' show TranscriptTurn;

part 'chat_transcript/message_rows.dart';
part 'chat_transcript/tool_batch.dart';
part 'chat_transcript/turn_meta.dart';

/// The row the transcript view writes itself, saying a compaction happened
/// here. Its own role, because an unknown role is read as the agent's.
const String kCompactionNoticeRole = 'compaction';

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

  /// By value: a live transcript is re-parsed whole on every poll, and an equal
  /// message is what lets its row skip the rebuild.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          other.role == role &&
          other.at == at &&
          other.pending == pending &&
          other.thinking == thinking &&
          _sameTool(other.tool, tool) &&
          other.text == text;

  @override
  int get hashCode => Object.hash(role, text, thinking, at, tool?.name);
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
      a.plan == b.plan;
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
    this.emptyHint = 'No messages yet.',
    this.onSaveNote,
    this.resolveHostPath,
    this.onPathTap,
    this.detailBuilder,
    this.turn = TranscriptTurn.unknown,
    this.earlier = 0,
    this.onLoadEarlier,
    this.firstOrdinal = 0,
    super.key,
  });

  final List<ChatMessage> messages;

  /// Messages before [messages] that are not held here but can be asked
  /// for with [onLoadEarlier] — a server-read transcript arrives a page at a
  /// time. Offered once every held message is shown.
  final int earlier;
  final VoidCallback? onLoadEarlier;

  /// The first message's place in the whole conversation, so a row keeps its
  /// key (and its open state) when [onLoadEarlier] puts older ones above it.
  final int firstOrdinal;
  final Widget? footer;
  final String emptyHint;

  /// Turns a path an agent wrote into one this process can open — a WSL
  /// `/mnt/c/…` into its Windows form. Omitted means they are already host paths.
  final String? Function(String path)? resolveHostPath;

  /// Where a file path a reader clicked goes — see [MarkdownMessage.onPathTap].
  /// Null leaves every path as plain text.
  final PathLinkCallback? onPathTap;

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
  int _lastLen = 0;
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _lastLen = widget.messages.length;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void didUpdateWidget(ChatTranscriptView old) {
    super.didUpdateWidget(old);
    if (widget.messages.length != _lastLen) {
      _lastLen = widget.messages.length;
      if (_stickToBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _stickToBottom = pos.pixels >= pos.maxScrollExtent - 24;
    if (pos.pixels > 80) return;
    if (_shown < widget.messages.length) {
      setState(() => _shown = math.min(_shown + _page, widget.messages.length));
    } else if (_canLoadEarlier) {
      widget.onLoadEarlier!();
    }
  }

  bool get _canLoadEarlier =>
      widget.earlier > 0 && widget.onLoadEarlier != null;

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
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
      for (var i = 0; i < rows.length; i++) keyOf(rows[i]): i + lead,
    };

    Widget rowAt(int offset) => _MessageRow(
      key: ValueKey<int>(base + offset),
      message: visible[offset],
      ordinal: start + offset,
      onSaveNote: widget.onSaveNote,
      resolveHostPath: widget.resolveHostPath,
      onPathTap: widget.onPathTap,
      detailBuilder: widget.detailBuilder,
    );

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
                child: FocusTraversalGroup(
                  child: total == 0
                      ? _ChatEmptyState(hint: widget.emptyHint)
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
                                child: ListView.builder(
                                  controller: _scroll,
                                  // The pane's whole width (owner, 2026-09-28),
                                  // with a gutter so no word touches its edge.
                                  padding: EdgeInsets.symmetric(
                                    horizontal: gutter,
                                    vertical: Insets.xl,
                                  ),
                                  itemCount: rows.length + lead,
                                  findChildIndexCallback: (key) =>
                                      indexOfKey[key],
                                  itemBuilder: (context, index) {
                                    if (lead == 1 && index == 0) {
                                      // Held here first; then, from the
                                      // server, the ones before those.
                                      final more = start > 0
                                          ? start
                                          : widget.earlier;
                                      return SelectionContainer.disabled(
                                        child: Center(
                                          child: TextButton.icon(
                                            onPressed: start > 0
                                                ? () => setState(
                                                    () => _shown = math.min(
                                                      _shown + _page,
                                                      total,
                                                    ),
                                                  )
                                                : widget.onLoadEarlier,
                                            icon: const Icon(AppIcons.caretUp),
                                            label: Text(
                                              'Load $more earlier message'
                                              '${more == 1 ? '' : 's'}',
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    final row = rows[index - lead];
                                    if (!row.isBatch) return rowAt(row.from);
                                    return _ToolBatchTile(
                                      key: keyOf(row),
                                      messages: visible,
                                      row: row,
                                      rowAt: rowAt,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
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
  const _ChatEmptyState({required this.hint});

  final String hint;

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
              Icon(
                isTerminalNotice ? AppIcons.terminal : AppIcons.robot,
                size: Chrome.iconHero,
                color: isTerminalNotice
                    ? scheme.onSurfaceVariant
                    : scheme.primary,
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
