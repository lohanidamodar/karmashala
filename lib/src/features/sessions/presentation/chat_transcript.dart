import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../domain/tool_activity.dart';
import 'markdown_message.dart';
import 'tool_activity_row.dart';

/// A normalized chat message for the transcript view, independent of whether it
/// came from a native session's event log or an imported CLI transcript.
class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.tool});

  /// `user`, `agent`, `tool`, or `error`.
  final String role;
  final String text;

  /// The structured call behind a `tool` row, when the source carried one.
  ///
  /// Null for a tool line we only have prose for — a CLI whose record we can
  /// only read as text, or the engine's own `Session ended.` marker. Those keep
  /// rendering exactly as they did.
  final ToolActivity? tool;
}

/// Called when the user keeps a message as a note: the message itself, and its
/// index in the whole transcript (not in the visible window), which is what the
/// note records as where it came from.
typedef SaveNoteCallback = void Function(ChatMessage message, int ordinal);

/// An extra widget to hang under one message's body, given the message and its
/// index in the whole transcript. Null — the answer for almost every row —
/// leaves that row exactly as it was.
///
/// The one caller is the subagent a `Task` call spawned. It is a builder rather
/// than a field on [ChatMessage] because what hangs there is a *widget* with
/// its own state and its own reads, and the transcript's message type is shared
/// with the remote and companion payloads, which have no widgets at all.
typedef MessageDetailBuilder =
    Widget? Function(ChatMessage message, int ordinal);

/// A CLI-style conversation list: user turns, agent replies and tool lines,
/// rendered close to how Claude Code / Codex print them. Long transcripts start
/// anchored at the newest message and load earlier turns on demand (a header
/// button plus auto-load when scrolled to the top).
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
  /// `/mnt/c/…` into its Windows form. Supplied by whoever knows the session's
  /// environment; omitted means the paths are already host paths.
  ///
  /// The translation is explicit and passed in rather than guessed at here,
  /// which is the rule the whole codebase follows (`PathTranslator`,
  /// `EditorActions.windowsPathFor`).
  final String? Function(String path)? resolveHostPath;

  /// Where a file path a reader clicked goes — see [MarkdownMessage.onPathTap].
  /// Null leaves every path as plain text, which is what a caller with no
  /// session to resolve against should do.
  final PathLinkCallback? onPathTap;

  /// Keeps a message as a note. Null hides the affordance entirely — the view
  /// knows nothing about the Notes feature or the setting behind it, only
  /// whether it was given somewhere to send one.
  final SaveNoteCallback? onSaveNote;

  /// What, if anything, hangs under a given row — see [MessageDetailBuilder].
  final MessageDetailBuilder? detailBuilder;

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
    final theme = Theme.of(context);
    final total = widget.messages.length;
    final start = math.max(0, total - _shown);
    final visible = widget.messages.sublist(start);

    return Column(
      children: [
        Expanded(
          child: total == 0
              ? Center(
                  child: Text(
                    widget.emptyHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.md,
                    vertical: Insets.sm,
                  ),
                  itemCount: visible.length + (start > 0 ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (start > 0 && index == 0) {
                      return Center(
                        child: TextButton.icon(
                          onPressed: () => setState(
                            () => _shown = math.min(_shown + _page, total),
                          ),
                          icon: const Icon(AppIcons.caretUp, size: 16),
                          label: Text(
                            'Load $start earlier message'
                            '${start == 1 ? '' : 's'}',
                          ),
                        ),
                      );
                    }
                    final offset = index - (start > 0 ? 1 : 0);
                    final message = visible[offset];
                    return _ChatMessageTile(
                      message: message,
                      resolveHostPath: widget.resolveHostPath,
                      onPathTap: widget.onPathTap,
                      detail: widget.detailBuilder?.call(
                        message,
                        start + offset,
                      ),
                      onSaveNote: widget.onSaveNote == null
                          ? null
                          : () => widget.onSaveNote!(message, start + offset),
                    );
                  },
                ),
        ),
        if (widget.footer != null) widget.footer!,
      ],
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (String gutter, Color color, String label) = switch (message.role) {
      'user' => ('›', scheme.primary, 'You'),
      'tool' => ('⏺', scheme.tertiary, 'Tool'),
      'error' => ('✗', scheme.error, 'Error'),
      _ => ('●', scheme.onSurface, 'Agent'),
    };

    final activity = message.tool;
    // A tool row is named by the tool that ran, not by the word "tool": an
    // eyebrow reading TOOL over a body reading `tool: Bash` was the same thing
    // written twice, and told the reader nothing about which call this was.
    final eyebrow = activity == null ? label : activity.name;
    final prose = message.role == 'user' || message.role == 'agent';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Text(
              gutter,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      eyebrow.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (onSaveNote != null)
                      _SaveNoteButton(onSave: onSaveNote!),
                    _CopyButton(text: message.text),
                  ],
                ),
                const SizedBox(height: 2),
                if (activity != null)
                  ToolActivityBody(
                    activity: activity,
                    resolveHostPath: resolveHostPath,
                    onPathTap: onPathTap,
                  )
                else if (prose)
                  MarkdownMessage(message.text, onPathTap: onPathTap)
                else
                  SelectableText(
                    message.text,
                    style: MonoStyles.label.copyWith(height: 1.35),
                  ),
                ?detail,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps this message as a note, in one tap.
///
/// It sits beside Copy because it is the same gesture with a different
/// destination, and it does the whole job on the first click: **the message's
/// own words become the note**. Nothing is summarised on the way — the point of
/// the feature is that you were mid-thought and did not want to stop, and a
/// dialog asking you to title it would be the interruption you were avoiding.
/// Titling and editing live in the Notes panel, afterwards.
class _SaveNoteButton extends StatefulWidget {
  const _SaveNoteButton({required this.onSave});
  final VoidCallback onSave;

  @override
  State<_SaveNoteButton> createState() => _SaveNoteButtonState();
}

class _SaveNoteButtonState extends State<_SaveNoteButton> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _saved ? 'Saved to Notes' : 'Save as note',
      visualDensity: VisualDensity.compact,
      iconSize: 13,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: EdgeInsets.zero,
      color: _saved ? SemanticColors.of(context).idle : scheme.onSurfaceVariant,
      icon: Icon(_saved ? AppIcons.check : AppIcons.notePencil),
      onPressed: () async {
        widget.onSave();
        if (!mounted) return;
        setState(() => _saved = true);
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _saved = false);
      },
    );
  }
}

/// A low-emphasis copy-to-clipboard button shown on each message.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _copied ? 'Copied' : 'Copy message',
      visualDensity: VisualDensity.compact,
      iconSize: 13,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: EdgeInsets.zero,
      color: _copied
          ? SemanticColors.of(context).idle
          : scheme.onSurfaceVariant,
      icon: Icon(_copied ? AppIcons.check : AppIcons.copySimple),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        setState(() => _copied = true);
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _copied = false);
      },
    );
  }
}
