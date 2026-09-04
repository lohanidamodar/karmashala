import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../explorer/presentation/session_card.dart' show compactAge;
import '../domain/tool_activity.dart';
import 'markdown_message.dart';
import 'tool_activity_row.dart';

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

  /// The structured call behind a `tool` row, when the source carried one.
  ///
  /// Null for a tool line we only have prose for — a CLI whose record we can
  /// only read as text, or the engine's own `Session ended.` marker. Those keep
  /// rendering exactly as they did.
  final ToolActivity? tool;

  /// Optional model reasoning or thinking process.
  final String? thinking;

  /// When the message was written.
  final DateTime? at;
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
    this.onSuggestionTap,
    super.key,
  });

  final List<ChatMessage> messages;
  final Widget? footer;
  final String emptyHint;

  /// Called when the user taps an empty-state suggestion prompt.
  final ValueChanged<String>? onSuggestionTap;

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
    final total = widget.messages.length;
    final start = math.max(0, total - _shown);
    final visible = widget.messages.sublist(start);

    return Column(
      children: [
        // The scrolling conversation is its own traversal group so that its
        // stops cannot interleave with the footer's. Reading order sorts by
        // rect, and tabbing to a row below the fold scrolls the list under the
        // policy's feet: every remaining row moves up past footer stops it had
        // already handed out, and the next Tab returns one of them. The group
        // collapses the whole list to a single sort key in the parent, so a
        // scroll can only reorder the list against itself — which it never
        // does, because it moves every row by the same amount.
        Expanded(
          child: FocusTraversalGroup(
            child: total == 0
                ? _ChatEmptyState(
                    hint: widget.emptyHint,
                    onSuggestionTap: widget.onSuggestionTap,
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
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
              constraints: const BoxConstraints(maxWidth: 860),
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
                vertical: Insets.xs + 2,
              ),
              child: Row(
                children: [
                  Icon(
                    AppIcons.chatCircleDots,
                    size: 14,
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
                    size: 14,
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

/// A welcoming empty state with interactive GenUI starter prompts.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({
    required this.hint,
    this.onSuggestionTap,
  });

  final String hint;
  final ValueChanged<String>? onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Check if hint is an explanatory terminal notice
    final isTerminalNotice = hint.contains('terminal is the session') ||
        hint.contains('no chat view') ||
        hint.contains('keeps no transcript');

    if (isTerminalNotice) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    AppIcons.terminal,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Insets.md),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                alignment: Alignment.center,
                child: Icon(AppIcons.robot, size: 26, color: scheme.primary),
              ),
              const SizedBox(height: Insets.md),
              Text(
                'Ready to assist',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (onSuggestionTap != null) ...[
                const SizedBox(height: Insets.lg),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  alignment: WrapAlignment.center,
                  children: [
                    _PromptSuggestionCard(
                      icon: AppIcons.code,
                      label: 'Explain project architecture',
                      onTap: () => onSuggestionTap!(
                        'Explain the architecture and main features of this project.',
                      ),
                    ),
                    _PromptSuggestionCard(
                      icon: AppIcons.playCircle,
                      label: 'Run tests and inspect failures',
                      onTap: () => onSuggestionTap!(
                        'Run the test suite and inspect any failures.',
                      ),
                    ),
                    _PromptSuggestionCard(
                      icon: AppIcons.magnifyingGlass,
                      label: 'Search codebase for TODOs',
                      onTap: () => onSuggestionTap!(
                        'Search the codebase for open TODOs and summarize them.',
                      ),
                    ),
                    _PromptSuggestionCard(
                      icon: AppIcons.gitBranch,
                      label: 'Review recent git commits',
                      onTap: () => onSuggestionTap!(
                        'Review recent git commits and explain latest changes.',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PromptSuggestionCard extends StatelessWidget {
  const _PromptSuggestionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        hoverColor: scheme.surfaceContainerHighest,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.primary),
              const SizedBox(width: Insets.sm),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final (String gutter, Color color, String label) = switch (message.role) {
      'user' => ('›', scheme.primary, 'You'),
      'tool' => ('⏺', scheme.tertiary, 'Tool'),
      'error' => ('✗', scheme.error, 'Error'),
      _ => ('●', scheme.onSurface, 'Agent'),
    };

    final activity = message.tool;
    final eyebrow = activity == null ? label : activity.name;
    final isUser = message.role == 'user';
    final isAgent = message.role == 'agent';
    final isError = message.role == 'error';

    final (thinking, cleanText) = isAgent
        ? _resolveThinking(message.text, message.thinking)
        : (null, message.text);

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.sm,
            Insets.md,
            Insets.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.userCircle, size: 15, color: scheme.primary),
                  const SizedBox(width: Insets.xs),
                  Text(
                    'YOU',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (message.at != null) ...[
                    const SizedBox(width: Insets.sm),
                    Text(
                      compactAge(DateTime.now().difference(message.at!)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
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
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  alignment: Alignment.center,
                  child: Icon(AppIcons.robot, size: 12, color: scheme.onSurface),
                ),
                const SizedBox(width: Insets.xs),
                Text(
                  'AGENT',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                if (message.at != null) ...[
                  const SizedBox(width: Insets.sm),
                  Text(
                    compactAge(DateTime.now().difference(message.at!)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
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
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: MarkdownMessage(cleanText, onPathTap: onPathTap),
            ),
            ?detail,
          ],
        ),
      );
    }

    if (isError) {
      final failure = SemanticColors.of(context).failure;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
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
              Icon(AppIcons.warningCircle, size: 16, color: failure),
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
                    const SizedBox(height: 2),
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
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
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
            padding: const EdgeInsets.all(Insets.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _toolIcon(activity?.name),
                      size: 15,
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
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: failure.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(Radii.sm),
                        ),
                        child: Text(
                          'FAILED',
                          style: TextStyle(
                            fontSize: 9,
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
