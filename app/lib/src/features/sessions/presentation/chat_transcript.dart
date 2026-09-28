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
    super.key,
  });

  final List<ChatMessage> messages;
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
    if (pos.pixels <= 80 && _shown < widget.messages.length) {
      setState(() => _shown = math.min(_shown + _page, widget.messages.length));
    }
  }

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
    final lead = start > 0 ? 1 : 0;
    // Rows are keyed by their ordinal in the whole transcript, so loading an
    // older page shifts indices without handing one row's element to another.
    // A live run has its own key, so its open state never outlives the turn.
    Key keyOf(TranscriptRow row) => row.live
        ? ValueKey<String>('${start + row.from}:live')
        : ValueKey<int>(start + row.from);
    final indexOfKey = <Key, int>{
      for (var i = 0; i < rows.length; i++) keyOf(rows[i]): i + lead,
    };

    Widget rowAt(int offset) => _MessageRow(
      key: ValueKey<int>(start + offset),
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
                                      return SelectionContainer.disabled(
                                        child: Center(
                                          child: TextButton.icon(
                                            onPressed: () => setState(
                                              () => _shown = math.min(
                                                _shown + _page,
                                                total,
                                              ),
                                            ),
                                            icon: const Icon(AppIcons.caretUp),
                                            label: Text(
                                              'Load $start earlier message'
                                              '${start == 1 ? '' : 's'}',
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

/// How long ago a message was written, as of the list's last build.
class _MessageAge extends StatelessWidget {
  const _MessageAge({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) => Text(
    compactAge(_TranscriptNow.of(context).difference(at)),
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// One message's row, built once per distinct input. The list rebuilds every
/// item on each poll; handing back the *same* tile instance is what stops an
/// unchanged message from building again. Callbacks are compared as given, so
/// a host passes stable ones (tear-offs) or pays for every row.
class _MessageRow extends StatefulWidget {
  const _MessageRow({
    required this.message,
    required this.ordinal,
    required this.onSaveNote,
    required this.resolveHostPath,
    required this.onPathTap,
    required this.detailBuilder,
    super.key,
  });

  final ChatMessage message;
  final int ordinal;
  final SaveNoteCallback? onSaveNote;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;
  final MessageDetailBuilder? detailBuilder;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  Widget? _tile;

  @override
  void didUpdateWidget(_MessageRow old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message ||
        old.ordinal != widget.ordinal ||
        old.onSaveNote != widget.onSaveNote ||
        old.resolveHostPath != widget.resolveHostPath ||
        old.onPathTap != widget.onPathTap ||
        old.detailBuilder != widget.detailBuilder) {
      _tile = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final ordinal = widget.ordinal;
    final save = widget.onSaveNote;
    return _tile ??= _ChatMessageTile(
      message: message,
      resolveHostPath: widget.resolveHostPath,
      onPathTap: widget.onPathTap,
      detail: widget.detailBuilder?.call(message, ordinal),
      onSaveNote: save == null ? null : () => save(message, ordinal),
    );
  }
}

class _ChatMessageTile extends StatelessWidget {
  const _ChatMessageTile({
    required this.message,
    this.onSaveNote,
    this.resolveHostPath,
    this.onPathTap,
    this.detail,
  });
  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;

  /// Hung under the body, indented with it: the subagent this row spawned.
  final Widget? detail;

  /// **One rhythm for every role**: two adjacent messages are always
  /// `Insets.lg` apart — the board's 18px gap, on the spacing scale. With no
  /// name row above each message any more, air is what separates them.
  static const _tileMargin = EdgeInsets.symmetric(vertical: Insets.sm);

  @override
  Widget build(BuildContext context) {
    ChatTranscriptView.debugMessageBuildCount++;
    return Padding(
      padding: _tileMargin,
      // Its own group, so a selection that runs into the next message copies
      // with a blank line between the two.
      child: TranscriptSelectionGroup(
        endsTurn: true,
        child: switch (message.role) {
          // Claude Code records an interruption as a user message; it is the
          // tool's note, not the person's words, so it is no bubble.
          'user' when _interruptionNote.hasMatch(message.text.trim()) =>
            _InterruptionNote(text: message.text.trim()),
          'user' => _UserMessageCard(
            message: message,
            onSaveNote: onSaveNote,
            onPathTap: onPathTap,
          ),
          'agent' => _AgentMessageBlock(
            message: message,
            onSaveNote: onSaveNote,
            onPathTap: onPathTap,
            detail: detail,
          ),
          'error' => _ErrorMessageCard(message: message),
          _ => _ToolMessageCard(
            message: message,
            onSaveNote: onSaveNote,
            resolveHostPath: resolveHostPath,
            onPathTap: onPathTap,
            detail: detail,
          ),
        },
      ),
    );
  }
}

/// Save-as-note, when notes are on, then Copy: every header's actions.
List<Widget> _messageActions(VoidCallback? onSaveNote, String copyText) => [
  if (onSaveNote != null) _SaveNoteButton(onSave: onSaveNote),
  _CopyButton(text: copyText),
];

/// Glyph, eyebrow and actions: a tool card's header row. The user's and the
/// agent's turns have none (board N2); their age and actions show on hover.
class _MessageHeader extends StatelessWidget {
  const _MessageHeader({
    required this.icon,
    required this.label,
    required this.color,
    this.fullLabel,
    this.badge,
    this.actions = const [],
  });

  final IconData icon;
  final String label;
  final Color color;

  /// The untruncated name, offered as a tooltip when [label] shortens it.
  final String? fullLabel;

  /// A marker right after the eyebrow, such as a failed call's.
  final Widget? badge;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // The shared header at the pointer's sizes, its defaults.
    return TranscriptRoleHeader(
      icon: icon,
      label: label,
      color: color,
      fullLabel: fullLabel,
      badge: badge,
      actions: actions,
    );
  }
}

/// A turn's age and its actions, drawn only while the pointer is over the turn
/// or focus is inside it (board N2: no name row above a message). Always laid
/// out and always in the semantics tree, so the row never shifts when it shows
/// and a screen reader or a keyboard user reaches Copy without hovering.
class _TurnMeta extends StatelessWidget {
  const _TurnMeta({
    required this.shown,
    required this.at,
    required this.actions,
  });

  final bool shown;
  final DateTime? at;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    return SelectionContainer.disabled(
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: Motion.of(context).fast,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (at != null) ...[
              _MessageAge(at: at),
              const SizedBox(width: Insets.xs),
            ],
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// A turn's body with its [_TurnMeta] beside it: at the end of the row where
/// the pane is wide, so the meta costs no height, and under the body where it
/// is narrow, so it costs the words none of their width.
class _TurnWithMeta extends StatefulWidget {
  const _TurnWithMeta({
    required this.body,
    required this.at,
    required this.actions,
    this.alignEnd = false,
  });

  final Widget body;
  final DateTime? at;
  final List<Widget> actions;

  /// The user's side: the body hugs the end and the meta sits before it.
  final bool alignEnd;

  @override
  State<_TurnWithMeta> createState() => _TurnWithMetaState();
}

/// Its own hover and focus state, so a pointer crossing a turn redraws that
/// turn's meta and never reaches the row cache above it.
class _TurnWithMetaState extends State<_TurnWithMeta> {
  /// Below this the meta goes under the body rather than beside it.
  static const _wideTurn = 480.0;

  bool _hovered = false;
  bool _focused = false;

  void _set({bool? hovered, bool? focused}) {
    final h = hovered ?? _hovered;
    final f = focused ?? _focused;
    if (h == _hovered && f == _focused) return;
    setState(() {
      _hovered = h;
      _focused = f;
    });
  }

  @override
  Widget build(BuildContext context) {
    final meta = _TurnMeta(
      shown: _hovered || _focused,
      at: widget.at,
      actions: widget.actions,
    );
    final end = widget.alignEnd;
    return MouseRegion(
      onEnter: (_) => _set(hovered: true),
      onExit: (_) => _set(hovered: false),
      // Listens for a descendant taking focus; never a stop of its own.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => _set(focused: focused),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < _wideTurn) {
              return Column(
                crossAxisAlignment: end
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [widget.body, meta],
              );
            }
            return Row(
              mainAxisAlignment: end
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              crossAxisAlignment: end
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: end
                  // Flexible: at the narrow end of wide the bubble's share
                  // plus the meta can exceed the row, and the bubble gives.
                  ? [
                      meta,
                      const SizedBox(width: Insets.xs),
                      Flexible(child: widget.body),
                    ]
                  : [
                      Expanded(child: widget.body),
                      const SizedBox(width: Insets.sm),
                      meta,
                    ],
            );
          },
        ),
      ),
    );
  }
}

class _UserMessageCard extends StatelessWidget {
  const _UserMessageCard({
    required this.message,
    required this.onSaveNote,
    required this.onPathTap,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final PathLinkCallback? onPathTap;

  /// The accent's share of the bubble's fill. Board N2 draws `#1c2230` on the
  /// `#0c0c0e` terminal tone with a `#7aa2f7` accent: 15% of the accent, in
  /// every channel. Derived, so a different accent tints its own bubble.
  static const _tintAlpha = 0.15;

  /// Board N2's `14 14 4 14`: the small corner points at the sender's side.
  static const _corners = BorderRadius.only(
    topLeft: Radius.circular(Radii.lg),
    topRight: Radius.circular(Radii.lg),
    bottomLeft: Radius.circular(Radii.lg),
    bottomRight: Radius.circular(Insets.xs),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A bubble on the right, tinted with the accent (spec §5): the agent's
    // turn is plain text on the left, so whose turn it is reads at a glance.
    final tint = Color.alphaBlend(
      scheme.primary.withValues(alpha: _tintAlpha),
      SurfaceTones.of(context).term,
    );
    return LayoutBuilder(
      builder: (context, constraints) => _TurnWithMeta(
        alignEnd: true,
        at: message.at,
        actions: _messageActions(onSaveNote, message.text),
        body: ConstrainedBox(
          // A share of the pane rather than the board's 560px: the column is
          // the pane's whole width now, and the gutter says whose turn it is.
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth * Chrome.chatBubbleShare,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: tint, borderRadius: _corners),
            child: Padding(
              // Board N2: 10 by 14.
              padding: const EdgeInsets.symmetric(
                horizontal: Radii.lg,
                vertical: Radii.md,
              ),
              child: MarkdownMessage(
                message.text,
                onPathTap: onPathTap,
                selectable: false,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentMessageBlock extends StatelessWidget {
  const _AgentMessageBlock({
    required this.message,
    required this.onSaveNote,
    required this.onPathTap,
    required this.detail,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final PathLinkCallback? onPathTap;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final (thinking, cleanText) = splitThinking(
      message.text,
      explicit: message.thinking,
    );
    // Plain text, no bubble and no name row (board N2): the agent's words are
    // the page, and the user's tinted bubbles are what mark the turns.
    return _TurnWithMeta(
      at: message.at,
      actions: _messageActions(onSaveNote, cleanText),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (thinking != null && thinking.isNotEmpty) ...[
            ThinkingAccordion(thinking: thinking),
            const SizedBox(height: Insets.xs),
          ],
          MarkdownMessage(cleanText, onPathTap: onPathTap, selectable: false),
          ?detail,
        ],
      ),
    );
  }
}

/// Claude Code's own "[Request interrupted by user…]" lines.
final _interruptionNote = RegExp(r'^\[Request interrupted by user[^\]]*\]$');

/// An interruption, said quietly on the agent's side: a muted line, since
/// the person did not type it.
class _InterruptionNote extends StatelessWidget {
  const _InterruptionNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final words = text.contains('tool use')
        ? 'Interrupted: you stopped the tool call'
        : 'Interrupted by you';
    return Row(
      children: [
        Icon(AppIcons.stopCircle, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            words,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _ErrorMessageCard extends StatelessWidget {
  const _ErrorMessageCard({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final failure = semantic.failure;
    return TranscriptTurnFrame(
      fill: semantic.failureSurface,
      edge: failure.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warningCircle, size: Chrome.iconSmall, color: failure),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionContainer.disabled(
                  child: Text(
                    'ERROR',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failure,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  message.text,
                  style: theme.textTheme.bodySmall?.copyWith(color: failure),
                ),
              ],
            ),
          ),
          _CopyButton(text: message.text),
        ],
      ),
    );
  }
}

/// A tool call, and every role this view does not name — a compaction notice,
/// or a role an importer invented, drawn as the agent's.
class _ToolMessageCard extends StatelessWidget {
  const _ToolMessageCard({
    required this.message,
    required this.onSaveNote,
    required this.resolveHostPath,
    required this.onPathTap,
    required this.detail,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failure = SemanticColors.of(context).failure;
    final activity = message.tool;
    final isToolError = activity?.isError == true;
    final accent = isToolError ? failure : scheme.tertiary;
    // A tool row's reasoning is only ever the field, never a scan of its text:
    // a tool row's text means `<thinking>` literally when it contains one.
    final thinking = message.role == 'tool' ? message.thinking?.trim() : null;
    final eyebrow =
        activity?.name ??
        switch (message.role) {
          'tool' => 'Tool',
          kCompactionNoticeRole => 'Compacted',
          _ => 'Agent',
        };
    final shown = toolDisplayName(eyebrow);

    return TranscriptTurnFrame(
      fill: theme.brightness == Brightness.dark
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow,
      edge: isToolError ? failure : scheme.outlineVariant,
      clip: true,
      // Tighter vertically than the other roles: a tool row is the most
      // repeated thing in a transcript, so 4px multiplies by every call.
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // An MCP name is wider than a narrow pane; it gives way first.
          _MessageHeader(
            icon: _toolIcon(activity?.name),
            label: shown,
            fullLabel: activity == null ? null : eyebrow,
            color: accent,
            badge: isToolError ? _FailedBadge(color: failure) : null,
            actions: _messageActions(
              onSaveNote,
              activity?.output ?? message.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          if (thinking != null && thinking.isNotEmpty) ...[
            ThinkingAccordion(thinking: thinking),
            const SizedBox(height: Insets.xs),
          ],
          if (activity != null)
            ToolActivityBody(
              activity: activity,
              resolveHostPath: resolveHostPath,
              onPathTap: onPathTap,
            )
          else
            Text(message.text, style: MonoStyles.label.copyWith(height: 1.35)),
          ?detail,
        ],
      ),
    );
  }
}

class _FailedBadge extends StatelessWidget {
  const _FailedBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        'FAILED',
        // The theme's smallest label rather than a 9pt literal, which ignores
        // a reader who scaled text up.
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

/// A run of tool calls as one line, opening into the rows it stands for.
/// Settled, the line says what the run did; live, it names the newest call.
/// Collapsed either way, with [TranscriptRow.pinned] drawn beneath it.
class _ToolBatchTile extends StatefulWidget {
  const _ToolBatchTile({
    required this.messages,
    required this.row,
    required this.rowAt,
    super.key,
  });

  /// The whole loaded window; [row] indexes into it.
  final List<ChatMessage> messages;
  final TranscriptRow row;
  final Widget Function(int offset) rowAt;

  @override
  State<_ToolBatchTile> createState() => _ToolBatchTileState();
}

class _ToolBatchTileState extends State<_ToolBatchTile> {
  bool _open = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final row = widget.row;
    final run = widget.messages.sublist(row.from, row.to);
    // Board N2's fold line: 12.5px, muted, turning to the foreground under
    // the pointer along with its wash.
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: _hovered ? scheme.onSurface : scheme.onSurfaceVariant,
    );
    final strong = muted?.copyWith(color: scheme.onSurface);

    final String label;
    final InlineSpan labelSpan;
    final String? detail;
    final IconData? glyph;
    if (row.live) {
      final newest = run.last.tool!;
      final subject = newest.subject?.split('\n').first;
      label = 'Working';
      labelSpan = TextSpan(text: label, style: strong);
      detail = subject == null || subject.isEmpty
          ? toolDisplayName(newest.name)
          : '${toolDisplayName(newest.name)}  $subject';
      glyph = _toolIcon(newest.name);
    } else {
      (label, labelSpan) = _settledLabel(run, strong: strong, muted: muted);
      detail = null;
      glyph = null;
    }
    final earlier = row.live && row.length > 1
        ? '${row.length} calls so far'
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectionContainer.disabled(
            child: Semantics(
              button: true,
              expanded: _open,
              label: [label, ?detail, ?earlier].join('. '),
              child: InkWell(
                onTap: () => setState(() => _open = !_open),
                onHover: (hovered) => setState(() => _hovered = hovered),
                hoverColor: tones.hover,
                borderRadius: BorderRadius.circular(Radii.sm),
                child: ConstrainedBox(
                  // Board N2: one 26px line, however many calls it stands for.
                  constraints: const BoxConstraints(minHeight: Chrome.row),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                    child: Row(
                      children: [
                        Icon(
                          _open ? AppIcons.caretDown : AppIcons.caretRight,
                          size: Chrome.iconSmall,
                          color: muted?.color,
                        ),
                        const SizedBox(width: Insets.sm),
                        if (glyph != null) ...[
                          // A still glyph, not a spinner: the activity line
                          // under the transcript already spins for the turn.
                          Icon(
                            glyph,
                            size: Chrome.iconSmall,
                            color: SemanticColors.of(context).working,
                          ),
                          const SizedBox(width: Insets.xs),
                        ],
                        Flexible(
                          flex: detail == null ? 1 : 0,
                          child: Text.rich(
                            labelSpan,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (detail != null) ...[
                          const SizedBox(width: Insets.sm),
                          Expanded(
                            child: Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: MonoStyles.body.copyWith(
                                color: muted?.color,
                              ),
                            ),
                          ),
                        ],
                        if (earlier != null) ...[
                          const SizedBox(width: Insets.sm),
                          Flexible(
                            child: Text(
                              earlier,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_open)
            // Board N2: the calls indented under the line, on a 1px rule.
            Padding(
              padding: const EdgeInsets.only(
                left: Insets.lg + Insets.hair * 2,
                top: Insets.hair * 2,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: Insets.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = row.from; i < row.to; i++)
                        _ToolCallLine(
                          message: widget.messages[i],
                          card: () => widget.rowAt(i),
                        ),
                    ],
                  ),
                ),
              ),
            )
          else
            for (final i in row.pinned) widget.rowAt(i),
        ],
      ),
    );
  }
}

/// A settled run's line as board N2 writes it — `Worked for 2m 12s · read 4
/// files · ran 3 commands` — with the first phrase in the foreground and the
/// rest muted. Returns the plain text too, for the semantics label.
///
/// With no duration the sentence is [describeToolRun]'s own, commas and all,
/// and only its first phrase is lifted: the words do not change with the
/// colouring, so the plain text reads the same to a finder and a reader.
(String, InlineSpan) _settledLabel(
  List<ChatMessage> run, {
  required TextStyle? strong,
  required TextStyle? muted,
}) {
  final worked = describeWorkedFor(run);
  final did = describeToolRun(run);
  if (worked != null) {
    final rest = did.isEmpty
        ? ''
        : ' · ${did[0].toLowerCase()}${did.substring(1).replaceAll(', ', ' · ')}';
    return (
      '$worked$rest',
      TextSpan(
        children: [
          TextSpan(text: worked, style: strong),
          TextSpan(text: rest, style: muted),
        ],
      ),
    );
  }
  final cut = [
    did.indexOf(', '),
    did.indexOf(' · '),
  ].where((i) => i > 0).fold<int>(did.length, math.min);
  return (
    did,
    TextSpan(
      children: [
        TextSpan(text: did.substring(0, cut), style: strong),
        TextSpan(text: did.substring(cut), style: muted),
      ],
    ),
  );
}

/// Commands whose passing is a result worth colouring: a test, analyze, lint
/// or check run. Anything else that exits cleanly only says how much it wrote.
final _checkCommand = RegExp(
  r'\b(test|tests|analy[sz]e|lint|check|checks|verify)\b',
);

/// One call inside an opened run (board N2): its glyph, its path or command
/// in mono, and what came of it at the far end. A click opens the full card
/// under it, output and all — the line is the index, the card the page.
class _ToolCallLine extends StatefulWidget {
  const _ToolCallLine({required this.message, required this.card});

  final ChatMessage message;

  /// The call's full row, built only once it is opened.
  final Widget Function() card;

  @override
  State<_ToolCallLine> createState() => _ToolCallLineState();
}

class _ToolCallLineState extends State<_ToolCallLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final message = widget.message;
    final tool = message.tool!;
    final kind = toolKindOf(tool.name);
    final subject = tool.subject?.split('\n').first.trim();
    final named = switch (kind) {
      ToolKind.read ||
      ToolKind.edit ||
      ToolKind.patch ||
      ToolKind.command ||
      ToolKind.search => false,
      _ => true,
    };
    final what = subject == null || subject.isEmpty
        ? toolDisplayName(tool.name)
        : named
        ? '${toolDisplayName(tool.name)}  $subject'
        : subject;
    final (result, resultColour) = _resultOf(
      message,
      kind,
      subject: subject,
      failure: semantic.failure,
      passed: semantic.idle,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectionContainer.disabled(
          child: Semantics(
            button: true,
            expanded: _open,
            label: '$what, $result',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              hoverColor: SurfaceTones.of(context).hover,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Chrome.row),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Icon(
                        _kindIcon(kind),
                        size: Chrome.iconSmall,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          what,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MonoStyles.body.copyWith(
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        result,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: resultColour ?? scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: widget.card(),
          ),
      ],
    );
  }
}

/// The glyph for what a call did, by the same kinds the fold line counts.
IconData _kindIcon(ToolKind kind) => switch (kind) {
  ToolKind.command => AppIcons.terminal,
  ToolKind.read => AppIcons.file,
  ToolKind.edit => AppIcons.pencilSimple,
  ToolKind.patch => AppIcons.gitDiff,
  ToolKind.search => AppIcons.magnifyingGlass,
  ToolKind.webSearch || ToolKind.webFetch => AppIcons.globe,
  ToolKind.delegate => AppIcons.robot,
  ToolKind.plan => AppIcons.listChecks,
  ToolKind.question => AppIcons.question,
  ToolKind.mcp || ToolKind.other => AppIcons.gearSix,
};

/// What came of one call, as the right end of its line says it: a failure in
/// the failure colour, a passing check in the healthy one, and otherwise the
/// plain fact the record holds — never a success nobody recorded.
(String, Color?) _resultOf(
  ChatMessage message,
  ToolKind kind, {
  required String? subject,
  required Color failure,
  required Color passed,
}) {
  final tool = message.tool!;
  if (tool.isError) return ('failed', failure);
  if (message.pending) return ('running', null);
  final output = tool.output?.trimRight() ?? '';
  final lines = output.isEmpty ? 0 : '\n'.allMatches(output).length + 1;
  final more = tool.outputTruncated ? '+' : '';
  String counted(String one, String many) =>
      lines == 1 && more.isEmpty ? '1 $one' : '$lines$more $many';
  return switch (kind) {
    ToolKind.read => ('read', null),
    ToolKind.edit => ('edited', null),
    ToolKind.patch => ('applied', null),
    ToolKind.search =>
      lines == 0 ? ('no matches', null) : (counted('match', 'matches'), null),
    ToolKind.command when subject != null && _checkCommand.hasMatch(subject) =>
      ('passed ✓', passed),
    ToolKind.command =>
      lines == 0 ? ('no output', null) : (counted('line', 'lines'), null),
    ToolKind.webSearch => ('searched', null),
    ToolKind.webFetch => ('fetched', null),
    ToolKind.plan => ('updated', null),
    ToolKind.question => ('answered', null),
    ToolKind.delegate || ToolKind.mcp || ToolKind.other => ('done', null),
  };
}

/// Keeps this message as a note, in one tap: its own words, nothing summarised
/// and no dialog — you were mid-thought. Titling lives in the Notes panel.
class _SaveNoteButton extends StatelessWidget {
  const _SaveNoteButton({required this.onSave});
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => _ConfirmingIconButton(
    icon: AppIcons.notePencil,
    tooltip: 'Save as note',
    confirmedTooltip: 'Saved to Notes',
    onPressed: () async => onSave(),
  );
}

/// A low-emphasis copy-to-clipboard button shown on each message.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => _ConfirmingIconButton(
    icon: AppIcons.copySimple,
    tooltip: 'Copy message',
    confirmedTooltip: 'Copied',
    onPressed: () => Clipboard.setData(ClipboardData(text: text)),
  );
}

/// A row action that shows a check for a moment once [onPressed] has done its
/// work. The moment ends with the row: a closed session leaves no timer.
class _ConfirmingIconButton extends StatefulWidget {
  const _ConfirmingIconButton({
    required this.icon,
    required this.tooltip,
    required this.confirmedTooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final String confirmedTooltip;
  final Future<void> Function() onPressed;

  @override
  State<_ConfirmingIconButton> createState() => _ConfirmingIconButtonState();
}

class _ConfirmingIconButtonState extends State<_ConfirmingIconButton> {
  static const _confirmFor = Duration(seconds: 2);
  Timer? _settle;

  bool get _confirmed => _settle?.isActive ?? false;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Future<void> _press() async {
    await widget.onPressed();
    if (!mounted) return;
    _settle?.cancel();
    setState(() {
      _settle = Timer(_confirmFor, () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = _confirmed;
    return IconButton(
      tooltip: confirmed ? widget.confirmedTooltip : widget.tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: Chrome.iconSmall,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: EdgeInsets.zero,
      color: confirmed
          ? SemanticColors.of(context).idle
          : Theme.of(context).colorScheme.onSurfaceVariant,
      icon: Icon(confirmed ? AppIcons.check : widget.icon),
      onPressed: _press,
    );
  }
}
