import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import 'markdown_message.dart';

/// A normalized chat message for the transcript view, independent of whether it
/// came from a native session's event log or an imported CLI transcript.
class ChatMessage {
  const ChatMessage({required this.role, required this.text});

  /// `user`, `agent`, `tool`, or `error`.
  final String role;
  final String text;
}

/// A CLI-style conversation list: user turns, agent replies and tool lines,
/// rendered close to how Claude Code / Codex print them. Long transcripts start
/// anchored at the newest message and load earlier turns on demand (a header
/// button plus auto-load when scrolled to the top).
class ChatTranscriptView extends StatefulWidget {
  const ChatTranscriptView({
    required this.messages,
    this.footer,
    this.emptyHint = 'No messages yet.',
    super.key,
  });

  final List<ChatMessage> messages;
  final Widget? footer;
  final String emptyHint;

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
                    final message = visible[index - (start > 0 ? 1 : 0)];
                    return _ChatMessageTile(message: message);
                  },
                ),
        ),
        if (widget.footer != null) widget.footer!,
      ],
    );
  }
}

class _ChatMessageTile extends StatelessWidget {
  const _ChatMessageTile({required this.message});
  final ChatMessage message;

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
                      label.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    _CopyButton(text: message.text),
                  ],
                ),
                const SizedBox(height: 2),
                if (prose)
                  MarkdownMessage(message.text)
                else
                  SelectableText(
                    message.text,
                    style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 12.5,
                      height: 1.35,
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
      color: _copied ? Colors.green : scheme.onSurfaceVariant,
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
