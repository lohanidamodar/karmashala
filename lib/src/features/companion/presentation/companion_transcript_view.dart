import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/presentation/chat_transcript.dart';
import '../../sessions/presentation/markdown_message.dart';
import 'package:karmashala_remote/companion.dart';

/// The phone's transcript: a conversation drawn from its newest message
/// upwards.
///
/// Reversed, so offset zero *is* the newest message. A forward list jumping to
/// `maxScrollExtent` lands short, because on a lazy list that extent is an
/// estimate from the children laid out so far.
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

  /// The gateway's account of an empty transcript: not a turn, and a session
  /// with a reason gets an explanation rather than a welcome.
  String? _absence() {
    for (final message in widget.messages) {
      if (message.role == kCompanionAbsenceRole) return message.text;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final absence = _absence();
    final turns = [
      for (final message in widget.messages)
        if (message.role != kCompanionAbsenceRole) message,
    ];
    final total = turns.length;

    return Column(
      children: [
        Expanded(
          child: total == 0
              // Which kind of nothing this is decides the screen: a welcome
              // over a session the user can see running reads as broken.
              ? absence != null
                    ? _TranscriptUnavailable(reason: absence)
                    : _CompanionEmptyState(
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
                  // Keyed by position in the whole window, so a message shifted
                  // by a newer arrival keeps its element and the sliver
                  // corrects offsets instead of redrawing under the reader.
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<int>) return null;
                    final index = total - 1 - key.value;
                    return index >= 0 && index < total ? index : null;
                  },
                  itemBuilder: (context, index) {
                    final ordinal = total - 1 - index;
                    final message = turns[ordinal];
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
        // Above the composer rather than floating in the list, so it cannot
        // overlap the newest turn at any text scale. Not animated: a sized
        // transition would relayout the viewport on every frame.
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

/// The top of what the phone was sent: the history the host kept back. A
/// boundary and not a message — the same words in a row read as the agent's.
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
///
/// Copying is a long press: a copy `IconButton` at the touch floor made every
/// gutter 48px tall for an 11px label, and a long press cannot compete with
/// the tap that opens a link inside the text.
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, super.key});

  final CompanionChatMessage message;

  /// The gutter: who is speaking, in one compact row, sized by the label rather
  /// than by a control. [leading] is the agent's avatar mark.
  Widget _gutter(
    ThemeData theme, {
    required Widget leading,
    required String label,
    required Color color,
    required double gap,
  }) => Row(
    children: [
      leading,
      SizedBox(width: gap),
      Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    // A phone reads at arm's length, so message text takes the same step up
    // the ramp that `UiDensity.muted` takes for supporting lines.
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: kMonoFamily);

    Widget tile({required Widget child, Color? fill, Color? edge}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: edge == null ? null : Border.all(color: edge),
        ),
        padding: fill == null && edge == null
            ? EdgeInsets.zero
            : const EdgeInsets.all(Insets.md),
        child: child,
      ),
    );

    if (message.role == 'user') {
      return tile(
        fill: scheme.surfaceContainerHigh,
        edge: scheme.outlineVariant.withValues(alpha: 0.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _gutter(
              theme,
              leading: Icon(
                AppIcons.userCircle,
                size: density.iconSmall,
                color: scheme.primary,
              ),
              label: 'YOU',
              color: scheme.primary,
              gap: density.glyphGap,
            ),
            const SizedBox(height: Insets.xs),
            MarkdownMessage(message.text),
          ],
        ),
      );
    }

    if (message.role == 'tool') {
      return tile(
        fill: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        edge: scheme.outlineVariant.withValues(alpha: 0.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _gutter(
              theme,
              leading: Icon(
                AppIcons.terminal,
                size: density.iconSmall,
                color: scheme.tertiary,
              ),
              label: 'TOOL',
              color: scheme.tertiary,
              gap: density.glyphGap,
            ),
            const SizedBox(height: Insets.xs),
            SelectableText(message.text, style: mono),
          ],
        ),
      );
    }

    if (message.role == 'error') {
      final failure = SemanticColors.of(context).failure;
      return tile(
        fill: failure.withValues(alpha: 0.08),
        edge: failure.withValues(alpha: 0.4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _gutter(
              theme,
              leading: Icon(
                AppIcons.warning,
                size: density.iconSmall,
                color: failure,
              ),
              label: 'ERROR',
              color: failure,
              gap: density.glyphGap,
            ),
            const SizedBox(height: Insets.xs),
            SelectableText(
              message.text,
              style: mono?.copyWith(color: failure),
            ),
          ],
        ),
      );
    }

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

    return tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _gutter(
            theme,
            leading: Container(
              width: Touch.icon + Insets.xs,
              height: Touch.icon + Insets.xs,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                AppIcons.robot,
                size: density.iconSmall,
                color: scheme.secondary,
              ),
            ),
            label: 'AGENT',
            color: scheme.onSurface,
            gap: density.glyphGap,
          ),
          if (thinking != null && thinking.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            ThinkingAccordion(thinking: thinking),
          ],
          const SizedBox(height: Insets.xs),
          MarkdownMessage(cleanText),
        ],
      ),
    );
  }
}

/// Why this session has no chat view — the host's fact, worded by the gateway.
/// Deliberately not the welcome state: the session is already running, and an
/// offer to type something reads as "this screen is broken".
class _TranscriptUnavailable extends StatelessWidget {
  const _TranscriptUnavailable({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HeroGlyph(
              icon: AppIcons.terminal,
              fill: scheme.surfaceContainerHigh,
              edge: scheme.outlineVariant,
              tint: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.md),
            Text(
              'No chat view for this session',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Insets.sm),
            // Left-aligned: centred prose reads as a slogan, and this has to
            // be followed.
            Text(
              reason,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
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
            _HeroGlyph(
              icon: AppIcons.robot,
              fill: scheme.primaryContainer.withValues(alpha: 0.4),
              edge: scheme.primary.withValues(alpha: 0.2),
              tint: scheme.primary,
            ),
            const SizedBox(height: Insets.md),
            Text(
              'Start a conversation',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Text(
                emptyHint,
                textAlign: TextAlign.center,
                // A paragraph, not a caption: `bodySmall` would set the only
                // text on this screen in the app's smallest size.
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (onSuggestionTap != null) ...[
              const SizedBox(height: Insets.xl),
              Wrap(
                // The floor between two targets, not half of it: at 4 a thumb
                // aiming for one chip can reach its neighbour.
                spacing: Touch.gap,
                runSpacing: Touch.gap,
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

/// The one picture on a screen with nothing else on it.
class _HeroGlyph extends StatelessWidget {
  const _HeroGlyph({
    required this.icon,
    required this.tint,
    this.fill,
    this.edge,
  });

  final IconData icon;
  final Color tint;
  final Color? fill;
  final Color? edge;

  @override
  Widget build(BuildContext context) => Container(
    // A ring the glyph's own size, so the mark scales with the token.
    width: Touch.iconHero + Insets.xl,
    height: Touch.iconHero + Insets.xl,
    decoration: BoxDecoration(
      color: fill,
      shape: BoxShape.circle,
      border: edge == null ? null : Border.all(color: edge!),
    ),
    alignment: Alignment.center,
    child: Icon(icon, size: Touch.iconHero, color: tint),
  );
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
      avatar: Icon(icon, size: Touch.iconSmall, color: scheme.primary),
      label: Text(label, style: theme.textTheme.bodyMedium),
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      shape: const StadiumBorder(),
      onPressed: () => onTap(prompt),
    );
  }
}
