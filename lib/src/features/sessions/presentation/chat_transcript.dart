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

  /// By value: a live transcript is re-parsed whole on every poll, and an equal
  /// message is what lets its row skip the rebuild.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          other.role == role &&
          other.at == at &&
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

/// How many finished, uneventful tool calls in a row become one line. Three,
/// because two read as a pair and twenty read as a wall.
const int kToolBatchMinimum = 3;

/// Whether this message may disappear into a batch. A failure, a call with no
/// result yet, and a call the model reasoned its way to are each the row a
/// reader is looking for — those never collapse.
bool batchableToolMessage(ChatMessage message) {
  final tool = message.tool;
  return message.role == 'tool' &&
      tool != null &&
      !tool.isError &&
      tool.output != null &&
      (message.thinking == null || message.thinking!.trim().isEmpty);
}

/// One row of the transcript: a message at [from], or the run of batchable tool
/// calls `[from, to)` when that run is at least [kToolBatchMinimum] long.
class TranscriptRow {
  const TranscriptRow(this.from, this.to);

  final int from;
  final int to;

  bool get isBatch => to - from > 1;
  int get length => to - from;
}

/// Groups runs of batchable tool calls, leaving every other message its own
/// row. Pure, and indexed into whatever list it was given.
List<TranscriptRow> transcriptRows(List<ChatMessage> messages) {
  final rows = <TranscriptRow>[];
  var i = 0;
  while (i < messages.length) {
    if (!batchableToolMessage(messages[i])) {
      rows.add(TranscriptRow(i, i + 1));
      i++;
      continue;
    }
    var end = i;
    while (end < messages.length && batchableToolMessage(messages[end])) {
      end++;
    }
    if (end - i >= kToolBatchMinimum) {
      rows.add(TranscriptRow(i, end));
    } else {
      for (var single = i; single < end; single++) {
        rows.add(TranscriptRow(single, single + 1));
      }
    }
    i = end;
  }
  return rows;
}

/// `Read ×9 · Bash ×3` — what the calls in a batch were, in the order
/// they first appeared, so the line says what happened and not just how much.
String describeToolBatch(Iterable<ChatMessage> messages) {
  final counts = <String, int>{};
  for (final message in messages) {
    final name = message.tool?.name ?? 'Tool';
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return [
    for (final entry in counts.entries)
      entry.value == 1 ? entry.key : '${entry.key} ×${entry.value}',
  ].join(' · ');
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
    final rows = transcriptRows(visible);
    final lead = start > 0 ? 1 : 0;
    // Rows are keyed by their ordinal in the whole transcript, so loading an
    // older page shifts indices without handing one row's element to another.
    final indexOfOrdinal = <int, int>{
      for (var i = 0; i < rows.length; i++) start + rows[i].from: i + lead,
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

    return LayoutBuilder(
      builder: (context, constraints) => Column(
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
                          maxWidth: Chrome.readableWidth,
                        ),
                        child: _TranscriptNow(
                          now: DateTime.now(),
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(
                              horizontal: Insets.md,
                              vertical: Insets.sm,
                            ),
                            itemCount: rows.length + lead,
                            findChildIndexCallback: (key) =>
                                key is ValueKey<int>
                                ? indexOfOrdinal[key.value]
                                : null,
                            itemBuilder: (context, index) {
                              if (lead == 1 && index == 0) {
                                return Center(
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
                                );
                              }
                              final row = rows[index - lead];
                              if (!row.isBatch) return rowAt(row.from);
                              return _ToolBatchTile(
                                key: ValueKey<int>(start + row.from),
                                // The run itself, so the line can name the calls.
                                messages: visible.sublist(row.from, row.to),
                                rowAt: rowAt,
                                from: row.from,
                              );
                            },
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
                    maxWidth: Chrome.readableWidth,
                  ),
                  child: widget.footer!,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

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
  /// `Insets.sm` apart. What marks a turn is the user card's fill, not air.
  static const _tileMargin = EdgeInsets.symmetric(vertical: Insets.xs);

  @override
  Widget build(BuildContext context) {
    ChatTranscriptView.debugMessageBuildCount++;
    return Padding(
      padding: _tileMargin,
      child: switch (message.role) {
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
    );
  }
}

/// Save-as-note, when notes are on, then Copy: every header's actions.
List<Widget> _messageActions(VoidCallback? onSaveNote, String copyText) => [
  if (onSaveNote != null) _SaveNoteButton(onSave: onSaveNote),
  _CopyButton(text: copyText),
];

/// Glyph, eyebrow, age and actions: the one header row every role draws. The
/// eyebrow and age give way before the actions do.
class _MessageHeader extends StatelessWidget {
  const _MessageHeader({
    required this.icon,
    required this.label,
    required this.color,
    this.at,
    this.fullLabel,
    this.badge,
    this.actions = const [],
  });

  final IconData icon;
  final String label;
  final Color color;
  final DateTime? at;

  /// The untruncated name, offered as a tooltip when [label] shortens it.
  final String? fullLabel;

  /// A marker right after the eyebrow, such as a failed call's.
  final Widget? badge;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    // The shared header at the pointer's sizes, its defaults.
    return TranscriptRoleHeader(
      icon: icon,
      label: label,
      color: color,
      fullLabel: fullLabel,
      badge: badge,
      meta: at == null ? null : _MessageAge(at: at),
      actions: actions,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TranscriptTurnFrame(
      // **No border.** `surfaceContainerHigh` already separates the card;
      // the tool card keeps its border because its fill barely differs.
      fill: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MessageHeader(
            icon: AppIcons.userCircle,
            label: 'You',
            color: scheme.primary,
            at: message.at,
            actions: _messageActions(onSaveNote, message.text),
          ),
          const SizedBox(height: Insets.xs),
          MarkdownMessage(message.text, onPathTap: onPathTap),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    final (thinking, cleanText) = splitThinking(
      message.text,
      explicit: message.thinking,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A bare glyph, sized and spaced exactly like the user row's. The
        // 20px bordered circle it replaced outranked its own row.
        _MessageHeader(
          icon: AppIcons.robot,
          label: 'Agent',
          color: scheme.onSurface,
          at: message.at,
          actions: _messageActions(onSaveNote, cleanText),
        ),
        const SizedBox(height: Insets.xs),
        if (thinking != null && thinking.isNotEmpty) ...[
          ThinkingAccordion(thinking: thinking),
          const SizedBox(height: Insets.xs),
        ],
        // Flush with the eyebrow above it: the 2px indent was too small to
        // read as one and enough to stop the body lining up with the glyph.
        MarkdownMessage(cleanText, onPathTap: onPathTap),
        ?detail,
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
                Text(
                  'ERROR',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: failure,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: Insets.xs),
                SelectableText(
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
            SelectableText(
              message.text,
              style: MonoStyles.label.copyWith(height: 1.35),
            ),
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

/// A run of finished tool calls as one line, opening into the rows it stands
/// for. Collapsed by default: between two of the model's sentences, twenty file
/// reads are one step.
class _ToolBatchTile extends StatefulWidget {
  const _ToolBatchTile({
    required this.messages,
    required this.rowAt,
    required this.from,
    super.key,
  });

  final List<ChatMessage> messages;
  final Widget Function(int offset) rowAt;
  final int from;

  @override
  State<_ToolBatchTile> createState() => _ToolBatchTileState();
}

class _ToolBatchTileState extends State<_ToolBatchTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = widget.messages.length;
    final summary = describeToolBatch(widget.messages);
    final label = '$count tool calls';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label: '$label. $summary',
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      _open ? AppIcons.caretDown : AppIcons.caretRight,
                      size: Chrome.iconAction,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.xs),
                    Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            for (var i = 0; i < count; i++) widget.rowAt(widget.from + i),
        ],
      ),
    );
  }
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
