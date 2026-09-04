import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../../sessions/presentation/markdown_message.dart';
import '../client/companion_gateway.dart';

/// The phone's transcript: a conversation drawn from its newest message
/// upwards.
///
/// The desktop's [ChatTranscriptView] is a forward list that jumps to
/// `maxScrollExtent` once, after the first frame. On a lazy list that extent is
/// an *estimate* from the children laid out so far, and a real session's newest
/// turns are its longest — measured on a 300-message window, opening one landed
/// 4391px short of the end with the newest message never built. That is the
/// "I cannot find the edge of the session" report. A reversed list has no
/// estimate to be wrong about: offset zero **is** the newest message, on the
/// first frame and on every frame after it.
class CompanionTranscriptView extends StatefulWidget {
  const CompanionTranscriptView({
    required this.messages,
    this.footer,
    this.emptyHint = 'No messages yet.',
    this.onSuggestionTap,
    super.key,
  });

  /// Oldest first, exactly as the gateway holds it; the list draws bottom-up.
  final List<CompanionChatMessage> messages;

  /// Pinned under the conversation — the approval card and the composer.
  final Widget? footer;

  final String emptyHint;

  /// Called when the user taps a suggested prompt from the empty state.
  final ValueChanged<String>? onSuggestionTap;

  @override
  State<CompanionTranscriptView> createState() =>
      _CompanionTranscriptViewState();
}

class _CompanionTranscriptViewState extends State<CompanionTranscriptView> {
  /// How far off the newest message still counts as being at the bottom.
  static const _slack = 24.0;

  final _scroll = ScrollController();
  bool _atLatest = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(CompanionTranscriptView old) {
    super.didUpdateWidget(old);
    // Only the reader who is already at the newest message is carried to the
    // next one; anyone reading history keeps the pixel they were on, which a
    // reversed list gives for free.
    if (_atLatest && widget.messages.length != old.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_scroll.position.pixels > 0) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atLatest = _scroll.position.pixels <= _slack;
    if (atLatest != _atLatest) setState(() => _atLatest = atLatest);
  }

  Future<void> _toLatest() =>
      _scroll.animateTo(0, duration: Motion.base, curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final total = widget.messages.length;

    return Column(
      children: [
        Expanded(
          child: total == 0
              ? _CompanionEmptyState(
                  emptyHint: widget.emptyHint,
                  onSuggestionTap: widget.onSuggestionTap,
                )
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.md,
                    vertical: Insets.sm,
                  ),
                  itemCount: total,
                  // Keyed by position in the whole window so a message that
                  // only moved because a newer one arrived keeps its element
                  // — the sliver then corrects its own offsets instead of
                  // redrawing different text under a reader.
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<int>) return null;
                    final index = total - 1 - key.value;
                    return index >= 0 && index < total ? index : null;
                  },
                  itemBuilder: (context, index) {
                    final ordinal = total - 1 - index;
                    final message = widget.messages[ordinal];
                    return message.role == kCompanionNoticeRole
                        ? _WindowTopNotice(
                            key: ValueKey<int>(ordinal),
                            text: message.text,
                          )
                        : _MessageTile(
                            key: ValueKey<int>(ordinal),
                            message: message,
                          );
                  },
                ),
        ),
        // Above the composer, not floating in the list. Centred over the
        // viewport it sat on the newest turn — the text the reader is
        // scrolling back *towards* — and reserving list padding instead would
        // mean hard-coding the pill's height, which moves with the text scale.
        // Out here it cannot overlap anything at any scale.
        //
        // Appearing and vanishing costs the list one relayout each, at the
        // single frame `_atLatest` flips; deliberately not animated, because a
        // sized transition would relayout the viewport on every frame of it.
        if (total > 0 && !_atLatest)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.xs,
              Insets.md,
              Insets.xs,
            ),
            child: Center(child: _JumpToLatest(onPressed: _toLatest)),
          ),
        if (widget.footer != null) widget.footer!,
      ],
    );
  }
}

/// The way back to the newest message, shown only once the reader has left it.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    icon: const Icon(AppIcons.arrowDown),
    label: const Text('Jump to latest', maxLines: 1),
  );
}

/// The top of what the phone was sent: the history the host kept back.
///
/// Drawn as a boundary rather than as a message on purpose — the same words in
/// a `tool` row read as something the agent said, and a reader looking for the
/// end of a conversation can mistake any message for the last one.
class _WindowTopNotice extends StatelessWidget {
  const _WindowTopNotice({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Container(
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              AppIcons.caretUp,
              size: density.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            SizedBox(width: density.glyphGap),
            Expanded(child: Text(text, style: density.muted(theme))),
          ],
        ),
      ),
    );
  }
}

/// One turn, in the desktop chat's shapes at a thumb's sizes.
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, super.key});

  final CompanionChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (message.role == 'user') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.userCircle, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'YOU',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _CopyButton(text: message.text),
                ],
              ),
              const SizedBox(height: 4),
              MarkdownMessage(message.text),
            ],
          ),
        ),
      );
    }

    if (message.role == 'tool') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.terminal, size: 15, color: scheme.tertiary),
                  const SizedBox(width: 6),
                  Text(
                    'TOOL',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.tertiary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _CopyButton(text: message.text),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                message.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (message.role == 'error') {
      final failure = SemanticColors.of(context).failure;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Container(
          decoration: BoxDecoration(
            color: failure.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: failure.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.warning, size: 15, color: failure),
                  const SizedBox(width: 6),
                  Text(
                    'ERROR',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failure,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _CopyButton(text: message.text),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                message.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  color: failure,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Agent message
    final text = message.text;
    final thinkingMatch = RegExp(
      r'<thinking>([\s\S]*?)</thinking>',
    ).firstMatch(text);
    final String? thinking = thinkingMatch?.group(1)?.trim();
    final String cleanText = thinkingMatch != null
        ? (text.substring(0, thinkingMatch.start) +
                text.substring(thinkingMatch.end))
            .trim()
        : text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
                child: Icon(AppIcons.robot, size: 12, color: scheme.secondary),
              ),
              const SizedBox(width: 6),
              Text(
                'AGENT',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _CopyButton(text: message.text),
            ],
          ),
          if (thinking != null && thinking.isNotEmpty) ...[
            const SizedBox(height: 4),
            ThinkingAccordion(thinking: thinking),
          ],
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: MarkdownMessage(cleanText),
          ),
        ],
      ),
    );
  }
}

/// Copy-to-clipboard, at a size a thumb can hit.
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
    final density = UiDensity.of(context);
    return IconButton(
      tooltip: _copied ? 'Copied' : 'Copy message',
      iconSize: density.icon,
      constraints: BoxConstraints(
        minWidth: density.minRow,
        minHeight: density.minRow,
      ),
      padding: EdgeInsets.zero,
      color: _copied ? SemanticColors.of(context).idle : scheme.onSurfaceVariant,
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

class _CompanionEmptyState extends StatelessWidget {
  const _CompanionEmptyState({
    required this.emptyHint,
    this.onSuggestionTap,
  });

  final String emptyHint;
  final ValueChanged<String>? onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Icon(
                AppIcons.robot,
                size: 24,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Start a conversation',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Insets.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Text(
                emptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (onSuggestionTap != null) ...[
              const SizedBox(height: Insets.lg),
              Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                alignment: WrapAlignment.center,
                children: [
                  _SuggestionChip(
                    icon: AppIcons.code,
                    label: 'Explain architecture',
                    prompt:
                        'Explain the architecture and main features of this project.',
                    onTap: onSuggestionTap!,
                  ),
                  _SuggestionChip(
                    icon: AppIcons.playCircle,
                    label: 'Run tests',
                    prompt: 'Run project tests and explain any failures',
                    onTap: onSuggestionTap!,
                  ),
                  _SuggestionChip(
                    icon: AppIcons.gitBranch,
                    label: 'Recent changes',
                    prompt: 'Summarize git status and recent changes',
                    onTap: onSuggestionTap!,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({
    required this.icon,
    required this.label,
    required this.prompt,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String prompt;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ActionChip(
      avatar: Icon(icon, size: 14, color: scheme.primary),
      label: Text(label, style: theme.textTheme.bodySmall),
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onPressed: () => onTap(prompt),
    );
  }
}
