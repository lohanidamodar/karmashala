import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../explorer/presentation/session_card.dart' show compactAge;
import 'package:agent_cli/stream.dart';
import 'markdown_message.dart';
import 'tool_activity_row.dart';

/// The one row the transcript view writes itself: the line that says a
/// compaction happened here and how much of the conversation is behind it. Its
/// own role rather than `agent`, because the rest of the file reads an unknown
/// role as the agent's and this would put the app's words in the model's mouth.
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
}

/// Called when the user keeps a message as a note: the message, and its index
/// in the whole transcript (not the visible window), which the note records as
/// where it came from.
typedef SaveNoteCallback = void Function(ChatMessage message, int ordinal);

/// An extra widget to hang under one message's body, given the message and its
/// index in the whole transcript. Null leaves that row exactly as it was.
///
/// A builder rather than a field on [ChatMessage] because what hangs there is a
/// widget with its own state and reads, and the transcript's message type is
/// shared with the remote and companion payloads, which have no widgets.
typedef MessageDetailBuilder =
    Widget? Function(ChatMessage message, int ordinal);

/// A CLI-style conversation list: user turns, agent replies and tool lines.
/// Long transcripts start anchored at the newest message and load earlier turns
/// on demand (a header button, plus auto-load when scrolled to the top).
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
  /// `/mnt/c/…` into its Windows form. Omitted means the paths are already host
  /// paths; the translation is passed in rather than guessed at here.
  final String? Function(String path)? resolveHostPath;

  /// Where a file path a reader clicked goes — see [MarkdownMessage.onPathTap].
  /// Null leaves every path as plain text.
  final PathLinkCallback? onPathTap;

  /// Keeps a message as a note. Null hides the affordance entirely — the view
  /// knows nothing about the Notes feature, only where it may send one.
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
    final total = widget.messages.length;
    final start = math.max(0, total - _shown);
    final visible = widget.messages.sublist(start);

    return Column(
      children: [
        // Its own traversal group so its stops cannot interleave with the
        // footer's: reading order sorts by rect, and tabbing to a row below the
        // fold scrolls the list out from under the policy's feet.
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
                      child: ListView.builder(
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
                                icon: const Icon(AppIcons.caretUp),
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
                  ),
          ),
        ),
        if (widget.footer != null)
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
              child: widget.footer!,
            ),
          ),
      ],
    );
  }
}

/// Extracts model reasoning from `<thinking>` tags or explicit fields.
(String?, String) _resolveThinking(String rawText, String? explicitThinking) {
  if (explicitThinking != null && explicitThinking.trim().isNotEmpty) {
    return (explicitThinking.trim(), rawText);
  }
  final match = RegExp(
    r'<(?:thinking|thought)>([\s\S]*?)<\/(?:thinking|thought)>',
  ).firstMatch(rawText);
  if (match != null) {
    final thought = match.group(1)?.trim();
    final clean = (rawText.substring(0, match.start) +
            rawText.substring(match.end))
        .trim();
    return (thought, clean);
  }
  return (null, rawText);
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

/// An interactive accordion for agent reasoning / chain-of-thought.
class ThinkingAccordion extends StatefulWidget {
  const ThinkingAccordion({required this.thinking, super.key});
  final String thinking;

  @override
  State<ThinkingAccordion> createState() => _ThinkingAccordionState();
}

class _ThinkingAccordionState extends State<ThinkingAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = widget.thinking.split('\n').length;
    final summary = lines <= 1 ? 'Thought' : 'Thought for $lines lines';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Insets.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xs,
              ),
              child: Row(
                children: [
                  Icon(
                    AppIcons.chatCircleDots,
                    size: Chrome.iconAction,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    summary,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? AppIcons.caretDown : AppIcons.caretRight,
                    size: Chrome.iconAction,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.sm),
              child: SelectableText(
                widget.thinking,
                style: MonoStyles.small.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the conversation says when it has nothing to say yet: one glyph, one
/// heading, and the sentence explaining which kind of nothing this is.
///
/// The four prompt cards that used to sit here are gone: at the 390x844 pins
/// all four overflowed their row (by 53, 78, 16 and 16 logical pixels), a card
/// needs ~393px, and the composer directly below already has the caret. Ctrl+P
/// and Snippets are the surface for a phrase you reuse, and unlike four frozen
/// strings they are the user's own; `companion_transcript_view.dart` keeps them
/// because a phone has no palette.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.hint});

  final String hint;

  /// Centred while it fits, scrollable the moment it does not: at the 260px
  /// this gets in `workbench_test.dart` the column overflowed by 37 logical
  /// pixels, and a pane is short whenever the window is or a split halves it.
  ///
  /// `minHeight` is what keeps the centring — the scroll view hands its child
  /// unbounded height, so a bare `Center` inside one centres nothing.
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
                color: isTerminalNotice ? scheme.onSurfaceVariant : scheme.primary,
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

  /// **One rhythm for every role.** Two adjacent messages are always
  /// `Insets.sm` apart — 4 above and 4 below, meeting in the middle. The old
  /// per-role values encoded nothing a reader could use: what marks the start
  /// of a turn is the user card's raised fill, not extra air.
  static const _tileMargin = EdgeInsets.symmetric(vertical: Insets.xs);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final label = switch (message.role) {
      'user' => 'You',
      'tool' => 'Tool',
      'error' => 'Error',
      kCompactionNoticeRole => 'Compacted',
      _ => 'Agent',
    };

    final activity = message.tool;
    final eyebrow = activity == null ? label : activity.name;
    final isUser = message.role == 'user';
    final isAgent = message.role == 'agent';
    final isError = message.role == 'error';

    // A tool row's reasoning is only ever the field, never a scan of its text:
    // 425 of Antigravity's 435 thinking blocks carry only the call beside them,
    // and a tool row's text means `<thinking>` literally when it contains one.
    final (thinking, cleanText) = isAgent
        ? _resolveThinking(message.text, message.thinking)
        : (message.role == 'tool' ? message.thinking?.trim() : null,
          message.text);

    if (isUser) {
      return Padding(
        padding: _tileMargin,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.md),
            // **No border.** `surfaceContainerHigh` is two steps up the ramp
            // from the page in both brightnesses, so the fill already separates
            // the card. The tool card keeps its border: its fill is barely a
            // step from the page and inverts direction between light and dark.
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.userCircle,
                    size: Chrome.iconSmall,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    'YOU',
                    // `labelSmall` is the chrome eyebrow and the theme spaces
                    // it at 0.8 on purpose; the 0.5 override made these unique.
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (message.at != null) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      compactAge(DateTime.now().difference(message.at!)),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (onSaveNote != null) _SaveNoteButton(onSave: onSaveNote!),
                  _CopyButton(text: message.text),
                ],
              ),
              const SizedBox(height: Insets.xs),
              MarkdownMessage(message.text, onPathTap: onPathTap),
            ],
          ),
        ),
      );
    }

    if (isAgent) {
      return Padding(
        padding: _tileMargin,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // A bare glyph, sized and spaced exactly like the user row's.
                // The 20px bordered circle it replaced outranked its own row.
                Icon(
                  AppIcons.robot,
                  size: Chrome.iconSmall,
                  color: scheme.onSurface,
                ),
                const SizedBox(width: Insets.xs),
                Text(
                  'AGENT',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (message.at != null) ...[
                  const SizedBox(width: Insets.sm),
                  Text(
                    compactAge(DateTime.now().difference(message.at!)),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                if (onSaveNote != null) _SaveNoteButton(onSave: onSaveNote!),
                _CopyButton(text: cleanText),
              ],
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
        ),
      );
    }

    if (isError) {
      final failure = SemanticColors.of(context).failure;
      return Padding(
        padding: _tileMargin,
        child: Container(
          padding: const EdgeInsets.all(Insets.sm),
          decoration: BoxDecoration(
            color: failure.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: failure.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.warningCircle,
                size: Chrome.iconSmall,
                color: failure,
              ),
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
        ),
      );
    }

    final failure = SemanticColors.of(context).failure;
    final isToolError = activity?.isError == true;
    return Padding(
      padding: _tileMargin,
      child: Container(
        decoration: BoxDecoration(
          color: dark
              ? scheme.surfaceContainerLowest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: isToolError ? failure : scheme.outlineVariant,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: Padding(
            // Tighter vertically than the other roles: a tool row is the most
            // repeated thing in a transcript, so 4px here multiplies by every
            // call the agent made — and it brought a tool-to-tool boundary into
            // line with the rest, at 36 logical pixels instead of 46.
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _toolIcon(activity?.name),
                      size: Chrome.iconSmall,
                      color: isToolError ? failure : scheme.tertiary,
                    ),
                    const SizedBox(width: Insets.xs),
                    Text(
                      eyebrow.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isToolError ? failure : scheme.tertiary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isToolError) ...[
                      const SizedBox(width: Insets.xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.xs,
                        ),
                        decoration: BoxDecoration(
                          color: failure.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Text(
                          'FAILED',
                          // The theme's smallest label rather than a 9pt
                          // literal, which ignores a reader who scaled text up.
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: failure,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (onSaveNote != null)
                      _SaveNoteButton(onSave: onSaveNote!),
                    _CopyButton(text: activity?.output ?? message.text),
                  ],
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
          ),
        ),
      ),
    );
  }
}

/// Keeps this message as a note, in one tap.
///
/// The message's own words become the note — nothing is summarised, and no
/// dialog asks for a title: the point is that you were mid-thought and did not
/// want to stop. Titling and editing live in the Notes panel, afterwards.
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
      iconSize: Chrome.iconSmall,
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
      iconSize: Chrome.iconSmall,
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
