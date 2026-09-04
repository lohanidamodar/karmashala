import 'package:flutter/material.dart';

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

  /// The gateway's account of an empty transcript, pulled out of the list: it
  /// is not a turn, and a session with a reason has an *explanation* rather
  /// than a welcome.
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
              // Which nothing this is decides which screen it gets. A welcome
              // offering starter prompts, on a session the user can see
              // running, was the "shows running but no transcript" report:
              // the desktop knew the agent keeps no readable record and the
              // phone drew onboarding over the top of the answer.
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
///
/// **Copying is a long press, not a button in every gutter.** Measured on a
/// 390x844 phone: an `IconButton` at the touch floor made every tile's gutter
/// 48px tall to carry an 11px label, so a one-line message spent 72px of the
/// list on 20px of text and three of them took a fifth of the transcript
/// viewport on chrome. A long press is already what a phone's chat means by
/// "do something with this message"; it cannot compete with the tap that opens
/// a link inside the text, because a tap and a long press are different
/// gestures with no arena to lose; and the target becomes the whole tile
/// rather than a 48px square. The snackbar is the confirmation the vanishing
/// tick used to be.
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, super.key});

  final CompanionChatMessage message;

  /// The gutter: who is speaking, in one compact row.
  ///
  /// Sized by the label rather than by a control, which is the whole of the
  /// space this view got back. [leading] lets the agent keep the redesign's
  /// avatar mark without every other role paying for a `Stack`.
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
    // A phone reads at arm's length: message text takes the step up the ramp
    // that `UiDensity.muted` already takes for supporting lines, so a tool row
    // is not the app's smallest type on its most-read screen.
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

/// Why this session has no chat view — the host's fact, worded by the gateway,
/// drawn as an answer rather than as onboarding.
///
/// Deliberately **not** the welcome state: no heading that invites a first
/// message, and no starter chips. The session is already running; what the
/// reader needs is the reason the list is empty, and an offer to type
/// something is the one thing that reads as "this screen is broken".
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
            // Left-aligned: three lines of prose centred reads as a slogan,
            // and this is an explanation the reader has to actually follow.
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
                // `bodySmall` is the ramp's 12 and this is a paragraph, not a
                // caption: the one screen with nothing else on it was setting
                // its only text in the app's smallest size.
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

/// The one picture on a screen with nothing else on it, at the touch size the
/// theme names for exactly that.
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
    // The glyph plus a ring of its own size around it, so the mark scales
    // with the token rather than with a hand-picked diameter.
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
