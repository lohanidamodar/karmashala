// The list's chrome: the new-since rule, the empty state and its inherited scopes.

part of '../chat_transcript.dart';

/// "New since you last looked", a rule either side.
class _NewSinceLine extends StatelessWidget {
  const _NewSinceLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final rule = Expanded(
      child: Divider(
        color: accent.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
      ),
    );
    return SelectionContainer.disabled(
      child: Padding(
        key: const ValueKey('chat-new-since'),
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        child: Row(
          children: [
            rule,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Text(
                'New since you last looked',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            rule,
          ],
        ),
      ),
    );
  }
}

/// The height the conversation's list is drawn in: the room above the
/// composer, which a card under a call keeps to so its answers stay in sight.
class ChatViewportRoom extends InheritedWidget {
  const ChatViewportRoom({
    required this.height,
    required super.child,
    super.key,
  });

  final double height;

  /// The room, or null outside a transcript.
  static double? of(BuildContext context) {
    final height = context
        .dependOnInheritedWidgetOfExactType<ChatViewportRoom>()
        ?.height;
    return height == null || !height.isFinite ? null : height;
  }

  @override
  bool updateShouldNotify(ChatViewportRoom oldWidget) =>
      height != oldWidget.height;
}

/// Touch only: which turn's actions a tap has shown. One at a time, so a
/// tap on another turn moves them there.
class _TappedTurn extends InheritedWidget {
  const _TappedTurn({required this.notifier, required super.child, super.key});

  final ValueNotifier<Object?> notifier;

  static ValueNotifier<Object?>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_TappedTurn>()?.notifier;

  @override
  bool updateShouldNotify(_TappedTurn oldWidget) =>
      oldWidget.notifier != notifier;
}

/// What the conversation says when it has nothing to say yet. The four prompt
/// cards that sat here overflowed their row at phone width and are gone.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.hint, this.agentId});

  final String hint;
  final String? agentId;

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
              if (isTerminalNotice)
                Icon(
                  AppIcons.terminal,
                  size: Chrome.iconHero,
                  color: scheme.onSurfaceVariant,
                )
              else if (agentId case final agentId?)
                AgentLogo(
                  agentId: agentId,
                  size: Chrome.iconHero,
                  color: scheme.primary,
                )
              else
                Icon(
                  AppIcons.robot,
                  size: Chrome.iconHero,
                  color: scheme.primary,
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
