import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';
import 'package:karmashala_remote/companion.dart';

/// The phone's transcript, drawn newest-first: reversed, so offset zero *is*
/// the newest message rather than a lazy list's estimated `maxScrollExtent`.
class CompanionTranscriptView extends StatefulWidget {
  const CompanionTranscriptView({
    required this.messages,
    this.footer,
    this.composer,
    this.emptyHint = 'No messages yet.',
    this.onSuggestionTap,
    super.key,
  });

  /// Oldest first, exactly as the gateway holds it; the list draws bottom-up.
  final List<CompanionChatMessage> messages;

  /// Between the conversation and [composer] — the approval card, the activity
  /// strip. Capped at [footerShare] of the height and scrolled inside, so it
  /// can never push the composer under the keyboard.
  final Widget? footer;

  /// Pinned at the bottom at its own height.
  final Widget? composer;

  /// The most of this view's height [footer] takes before it scrolls.
  static const footerShare = 0.5;

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

    return CustomMultiChildLayout(
      delegate: _TranscriptLayout(),
      children: [
        LayoutId(
          id: _Slot.list,
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
                  // Keyed by position in the whole window, so a message
                  // shifted by a newer arrival keeps its element and the
                  // sliver corrects offsets instead of redrawing under it.
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
          LayoutId(
            id: _Slot.jump,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                Insets.xs,
                Insets.md,
                Insets.xs,
              ),
              // `heightFactor` keeps it its own height inside a bounded slot.
              child: Center(
                heightFactor: 1,
                child: _JumpToLatest(onPressed: _toLatest),
              ),
            ),
          ),
        if (widget.footer case final footer?)
          LayoutId(
            id: _Slot.footer,
            child: SingleChildScrollView(child: footer),
          ),
        if (widget.composer case final composer?)
          LayoutId(id: _Slot.composer, child: composer),
      ],
    );
  }
}

enum _Slot { list, jump, footer, composer }

/// The composer at its own height first, then the jump button, then the footer
/// in at most [CompanionTranscriptView.footerShare] of what is left; the list
/// takes the rest. A [Column] could not: a loose flexible footer leaves a gap.
class _TranscriptLayout extends MultiChildLayoutDelegate {
  _TranscriptLayout();

  @override
  void performLayout(Size size) {
    var room = size.height;
    double place(_Slot slot, double maxHeight) {
      if (!hasChild(slot)) return 0;
      return layoutChild(
        slot,
        BoxConstraints(
          minWidth: size.width,
          maxWidth: size.width,
          maxHeight: maxHeight < 0 ? 0 : maxHeight,
        ),
      ).height;
    }

    final composer = place(_Slot.composer, room);
    room -= composer;
    final jump = place(_Slot.jump, room);
    room -= jump;
    final footer = place(
      _Slot.footer,
      room * CompanionTranscriptView.footerShare,
    );
    room = room - footer < 0 ? 0 : room - footer;
    if (hasChild(_Slot.list)) {
      layoutChild(
        _Slot.list,
        BoxConstraints.tightFor(width: size.width, height: room),
      );
      positionChild(_Slot.list, Offset.zero);
    }
    if (hasChild(_Slot.jump)) positionChild(_Slot.jump, Offset(0, room));
    if (hasChild(_Slot.footer)) {
      positionChild(_Slot.footer, Offset(0, room + jump));
    }
    if (hasChild(_Slot.composer)) {
      positionChild(_Slot.composer, Offset(0, size.height - composer));
    }
  }

  @override
  bool shouldRelayout(_TranscriptLayout oldDelegate) => false;
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

/// How one speaker's turn is drawn: the gutter's glyph, word and colour, and
/// the frame round the turn — null [fill] and [edge] for the agent, whose turns
/// read as the page itself.
class CompanionTurnStyle {
  const CompanionTurnStyle({
    required this.icon,
    required this.label,
    required this.colour,
    this.iconColour,
    this.ring,
    this.fill,
    this.edge,
  });

  final IconData icon;
  final String label;

  /// The label's colour, and the glyph's unless [iconColour] says otherwise.
  final Color colour;
  final Color? iconColour;

  /// A filled circle behind the glyph: the agent's avatar mark.
  final Color? ring;
  final Color? fill;
  final Color? edge;
}

/// The one table of speakers. Anything the host sends that is not a user, a
/// tool or an error is the agent.
CompanionTurnStyle companionTurnStyle(
  String role,
  ColorScheme scheme,
  SemanticColors semantic,
) => switch (role) {
  'user' => CompanionTurnStyle(
    icon: AppIcons.userCircle,
    label: 'YOU',
    colour: scheme.primary,
    fill: scheme.surfaceContainerHigh,
    edge: scheme.outlineVariant.withValues(alpha: _faintEdge),
  ),
  'tool' => CompanionTurnStyle(
    icon: AppIcons.terminal,
    label: 'TOOL',
    colour: scheme.tertiary,
    fill: scheme.surfaceContainerHighest.withValues(alpha: _faintEdge),
    edge: scheme.outlineVariant.withValues(alpha: _faintEdge),
  ),
  'error' => CompanionTurnStyle(
    icon: AppIcons.warning,
    label: 'ERROR',
    colour: semantic.failure,
    fill: semantic.failureSurface,
    edge: semantic.failure.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
  ),
  _ => CompanionTurnStyle(
    icon: AppIcons.robot,
    label: 'AGENT',
    colour: scheme.onSurface,
    iconColour: scheme.secondary,
    ring: scheme.secondaryContainer.withValues(alpha: _avatarRing),
  ),
};

const _faintEdge = 0.35;
const _avatarRing = 0.4;

/// One turn, at a thumb's sizes. Copying is a long press: a copy button at the
/// touch floor made every gutter 48px tall for an 11px label.
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, super.key});

  final CompanionChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = companionTurnStyle(
      message.role,
      theme.colorScheme,
      SemanticColors.of(context),
    );
    // A phone reads at arm's length, so message text takes the same step up
    // the ramp that `UiDensity.muted` takes for supporting lines.
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: kMonoFamily);
    final (thinking, clean) = switch (message.role) {
      'user' || 'tool' || 'error' => (null, message.text),
      _ => splitThinking(message.text),
    };
    return _TurnFrame(
      fill: style.fill,
      edge: style.edge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RoleGutter(style: style),
          if (thinking != null && thinking.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            ThinkingAccordion(thinking: thinking),
          ],
          const SizedBox(height: Insets.xs),
          switch (message.role) {
            'tool' => SelectableText(clean, style: mono),
            'error' => SelectableText(
              clean,
              style: mono?.copyWith(color: style.colour),
            ),
            _ => MarkdownMessage(clean),
          },
        ],
      ),
    );
  }
}

/// The rounded frame round a turn, at the phone's roomier radius and padding.
class _TurnFrame extends StatelessWidget {
  const _TurnFrame({required this.child, this.fill, this.edge});

  final Widget child;
  final Color? fill;
  final Color? edge;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
    child: TranscriptTurnFrame(
      fill: fill,
      edge: edge,
      radius: Radii.lg,
      padding: const EdgeInsets.all(Insets.md),
      child: child,
    ),
  );
}

/// Who is speaking: the shared header at this density's sizes.
class _RoleGutter extends StatelessWidget {
  const _RoleGutter({required this.style});

  final CompanionTurnStyle style;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    return TranscriptRoleHeader(
      icon: style.icon,
      label: style.label,
      color: style.colour,
      iconColor: style.iconColour,
      ring: style.ring,
      ringDiameter: Touch.icon + Insets.xs,
      iconSize: density.iconSmall,
      gap: density.glyphGap,
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
  const _CompanionEmptyState({required this.emptyHint, this.onSuggestionTap});

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
              edge: StateLayers.selectedFocused(scheme),
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
