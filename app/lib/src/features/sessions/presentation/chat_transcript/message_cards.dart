// The person's message card, session notes, the agent's prose block and its model.

part of '../chat_transcript.dart';

class _UserMessageCard extends StatelessWidget {
  const _UserMessageCard({
    required this.message,
    required this.onSaveNote,
    required this.onPathTap,
    required this.onLinkTap,
    required this.resolveHostPath,
    this.onCopyTurn,
    this.turn = const [],
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final String Function()? onCopyTurn;
  final PathLinkCallback? onPathTap;
  final ValueChanged<String>? onLinkTap;
  final String? Function(String path)? resolveHostPath;
  final List<_TurnAction> turn;

  /// The accent's share of the bubble's fill. Board N2 draws `#1c2230` on the
  /// `#0c0c0e` terminal tone with a `#7aa2f7` accent: 15% of the accent, in
  /// every channel. Derived, so a different accent tints its own bubble.
  static const _tintAlpha = 0.15;

  /// Board N2's `14 14 4 14`: the small corner points at the sender's side.
  static const _corners = BorderRadius.only(
    topLeft: Radius.circular(Radii.lg),
    topRight: Radius.circular(Radii.lg),
    bottomLeft: Radius.circular(Radii.lg),
    bottomRight: Radius.circular(Insets.xs),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A bubble on the right, tinted with the accent (spec §5): the agent's
    // turn is plain text on the left, so whose turn it is reads at a glance.
    // A mix of two opaque colours, not a state layer laid over the row.
    final tint = Color.lerp(
      SurfaceTones.of(context).term,
      scheme.primary,
      _tintAlpha,
    )!;
    // An automation's message says so, in a label, not in its first line.
    final sent = AutomationAttribution.split(message.text);
    // Karmashala's own note to the agent is not the person's words.
    final (:preamble, :rest) = splitScratchPreamble(sent?.rest ?? message.text);
    final bubble = LayoutBuilder(
      builder: (context, constraints) => _TurnWithMeta(
        alignEnd: true,
        at: message.at,
        actions: _messageActions(
          onSaveNote,
          message.text,
          copyTurn: onCopyTurn,
          turn: turn,
        ),
        body: ConstrainedBox(
          // A share of the pane rather than the board's 560px: the column is
          // the pane's whole width now, and the gutter says whose turn it is.
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth * Chrome.chatBubbleShare,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(color: tint, borderRadius: _corners),
            child: Padding(
              // Board N2: 10 by 14.
              padding: const EdgeInsets.symmetric(
                horizontal: Radii.lg,
                vertical: Radii.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // What they pasted, drawn rather than left as "[Image #1]".
                  for (final path in message.images)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Insets.xs),
                      child: TranscriptImagePreview(
                        path: path,
                        resolveHostPath: resolveHostPath,
                      ),
                    ),
                  if (rest.isNotEmpty)
                    MarkdownMessage(
                      rest,
                      onPathTap: onPathTap,
                      onLinkTap: onLinkTap,
                      selectable: false,
                      foldLong: true,
                      // A long paste reads as the prompt it is, not a page.
                      foldAt: 12,
                      foldTo: 8,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (preamble == null && !message.queued && sent == null) return bubble;
    final muted = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (sent != null) AutomationSentLabel(by: sent.by),
        if (preamble != null) _SessionNote(text: preamble),
        if (rest.isNotEmpty || message.images.isNotEmpty) bubble,
        // The agent read it mid-turn, not as the next turn.
        if (message.queued)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text('Sent while working', style: muted),
          ),
      ],
    );
  }
}

/// What Karmashala told the agent ahead of the person's first words, folded
/// to one line.
class _SessionNote extends StatefulWidget {
  const _SessionNote({required this.text, this.label = 'Session note'});

  final String text;
  final String label;

  @override
  State<_SessionNote> createState() => _SessionNoteState();
}

class _SessionNoteState extends State<_SessionNote> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectionContainer.disabled(
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _open ? AppIcons.caretDown : AppIcons.caretRight,
                    size: Chrome.iconSmall,
                    color: muted?.color,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(widget.label, style: muted),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: Insets.lg, bottom: Insets.sm),
            child: Text(widget.text, style: muted),
          ),
      ],
    );
  }
}

class _AgentMessageBlock extends StatelessWidget {
  const _AgentMessageBlock({
    required this.message,
    required this.onSaveNote,
    required this.onPathTap,
    required this.onLinkTap,
    required this.detail,
    this.onCopyTurn,
    this.turn = const [],
    this.prose,
    this.sentencePerLine = false,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final PathLinkCallback? onPathTap;
  final ValueChanged<String>? onLinkTap;
  final Widget? detail;
  final String Function()? onCopyTurn;
  final List<_TurnAction> turn;
  final AgentProse? prose;
  final bool sentencePerLine;

  @override
  Widget build(BuildContext context) {
    final (thinking, cleanText) = splitThinking(
      message.text,
      explicit: message.thinking,
    );
    final scheme = Theme.of(context).colorScheme;
    final quiet = prose == AgentProse.quiet;
    final body = Column(
      key: switch (prose) {
        AgentProse.quiet => const ValueKey('chat-narration-quiet'),
        AgentProse.finalAnswer => const ValueKey('chat-final-answer'),
        null => null,
      },
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.agentName case final name?) ...[
          _AgentByline(name: name, agentId: message.agentId),
          const SizedBox(height: Insets.xs),
        ],
        if (message.model case final model?) ...[
          _TurnModel(label: model),
          const SizedBox(height: Insets.xs),
        ],
        if (thinking != null && thinking.isNotEmpty) ...[
          ThinkingAccordion(thinking: thinking),
          const SizedBox(height: Insets.xs),
        ],
        MarkdownMessage(
          cleanText,
          onPathTap: onPathTap,
          onLinkTap: onLinkTap,
          selectable: false,
          foldLong: true,
          color: quiet ? scheme.onSurfaceVariant : null,
          sentencePerLine: sentencePerLine,
        ),
        TranscriptImageStrip(paths: inlineImagePaths(cleanText)),
        ?detail,
      ],
    );
    // Plain text, no bubble and no name row (board N2): the agent's words are
    // the page, and the user's tinted bubbles are what mark the turns. The
    // answer a turn of work ends on hangs off an accent rule.
    return _TurnWithMeta(
      at: message.at,
      actions: _messageActions(
        onSaveNote,
        cleanText,
        copyTurn: onCopyTurn,
        turn: turn,
      ),
      body: prose != AgentProse.finalAnswer
          ? body
          : Semantics(
              container: true,
              label: 'Final answer',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: BorderDirectional(
                    start: BorderSide(
                      color: scheme.primary,
                      width: Chrome.answerRule,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: Insets.md),
                  child: body,
                ),
              ),
            ),
    );
  }
}

/// The model that wrote an agent turn, said small where it changed.
class _TurnModel extends StatelessWidget {
  const _TurnModel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: 'Model: $label',
      excludeSemantics: true,
      child: Row(
        key: const ValueKey('chat-turn-model'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.robot, size: Chrome.iconSmall, color: muted),
          const SizedBox(width: Insets.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
