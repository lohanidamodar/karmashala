part of '../chat_transcript.dart';

/// One message's row, built once per distinct input. The list rebuilds every
/// item on each poll; handing back the *same* tile instance is what stops an
/// unchanged message from building again. Callbacks are compared as given, so
/// a host passes stable ones (tear-offs) or pays for every row.
class _MessageRow extends StatefulWidget {
  const _MessageRow({
    required this.message,
    this.previousPlan,
    required this.ordinal,
    required this.onSaveNote,
    required this.resolveHostPath,
    required this.onPathTap,
    required this.onLinkTap,
    required this.detailBuilder,
    this.turnText,
    this.preview,
    this.onPreview,
    this.onClosePreview,
    this.previewBuilder,
  });

  /// The path whose preview hangs under this row, as it was written.
  final String? preview;

  /// Opens a preview under the row at an ordinal; null leaves path taps to
  /// [onPathTap].
  final void Function(int ordinal, String token)? onPreview;
  final void Function(int ordinal)? onClosePreview;
  final Widget Function(String token, VoidCallback onClose)? previewBuilder;

  final ChatMessage message;

  /// The plan a plan row replaced, so it can say what changed.
  final AgentPlan? previousPlan;
  final int ordinal;

  /// The whole turn around [ordinal] as text, asked for when it is copied.
  final String Function(int ordinal)? turnText;
  final SaveNoteCallback? onSaveNote;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;
  final ValueChanged<String>? onLinkTap;
  final MessageDetailBuilder? detailBuilder;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  Widget? _tile;

  @override
  void didUpdateWidget(_MessageRow old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message ||
        old.previousPlan != widget.previousPlan ||
        old.ordinal != widget.ordinal ||
        old.onSaveNote != widget.onSaveNote ||
        old.resolveHostPath != widget.resolveHostPath ||
        old.onPathTap != widget.onPathTap ||
        old.onLinkTap != widget.onLinkTap ||
        old.detailBuilder != widget.detailBuilder ||
        old.turnText != widget.turnText ||
        old.preview != widget.preview ||
        old.onPreview != widget.onPreview ||
        old.onClosePreview != widget.onClosePreview ||
        old.previewBuilder != widget.previewBuilder) {
      _tile = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final ordinal = widget.ordinal;
    final save = widget.onSaveNote;
    final turn = widget.turnText;
    final onPreview = widget.onPreview;
    final token = widget.preview;
    final builder = widget.previewBuilder;
    final close = widget.onClosePreview;
    // Its own boundary: one message that cannot be drawn must not take the
    // conversation with it.
    return _tile ??= MessageBoundary(
      raw: rawMessageText(message),
      child: _ChatMessageTile(
        message: message,
        previousPlan: widget.previousPlan,
        resolveHostPath: widget.resolveHostPath,
        onPathTap: onPreview == null
            ? widget.onPathTap
            : (path) => onPreview(ordinal, path),
        preview: token == null || builder == null
            ? null
            : MessageBoundary(
                raw: token,
                child: builder(token, () => close?.call(ordinal)),
              ),
        onLinkTap: widget.onLinkTap,
        detail: widget.detailBuilder?.call(message, ordinal),
        onSaveNote: save == null ? null : () => save(message, ordinal),
        onCopyTurn: turn == null ? null : () => turn(ordinal),
      ),
    );
  }
}

class _ChatMessageTile extends StatelessWidget {
  const _ChatMessageTile({
    required this.message,
    this.previousPlan,
    this.onSaveNote,
    this.onCopyTurn,
    this.resolveHostPath,
    this.onPathTap,
    this.onLinkTap,
    this.detail,
    this.preview,
  });
  final ChatMessage message;
  final AgentPlan? previousPlan;

  /// A file the reader opened from this message, under its body.
  final Widget? preview;
  final VoidCallback? onSaveNote;
  final String Function()? onCopyTurn;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;
  final ValueChanged<String>? onLinkTap;

  /// Hung under the body, indented with it: the subagent this row spawned.
  final Widget? detail;

  /// **One rhythm for every role**: two adjacent messages are always
  /// `Insets.lg` apart — the board's 18px gap, on the spacing scale. With no
  /// name row above each message any more, air is what separates them.
  static const _tileMargin = EdgeInsets.symmetric(vertical: Insets.sm);

  @override
  Widget build(BuildContext context) {
    ChatTranscriptView.debugMessageBuildCount++;
    final body = _body();
    final preview = this.preview;
    return Padding(
      padding: _tileMargin,
      // Its own group, so a selection that runs into the next message copies
      // with a blank line between the two.
      child: TranscriptSelectionGroup(
        endsTurn: true,
        child: preview == null
            ? body
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [body, preview],
              ),
      ),
    );
  }

  Widget _body() => switch (message.role) {
    // A plan, whoever filed it: drawn as the agent's checklist.
    _ when message.role != 'user' && message.tool?.plan != null =>
      PlanUpdateCard(plan: message.tool!.plan!, previous: previousPlan),
    // A plan put to the person, once answered: kept, saying how.
    _
        when message.tool?.proposedPlan != null &&
            !message.pending &&
            message.tool!.output != null =>
      _AnsweredPlanCard(tool: message.tool!),
    // Questions put to the person, once answered: each with its pick.
    _
        when (message.tool?.questions.isNotEmpty ?? false) &&
            !message.pending &&
            message.tool!.output != null =>
      _AnsweredQuestionsCard(questions: message.tool!.questions),
    // Claude Code records an interruption as a user message; it is the
    // tool's note, not the person's words, so it is no bubble.
    'user' when _interruptionNote.hasMatch(message.text.trim()) =>
      _InterruptionNote(text: message.text.trim()),
    // A background run reporting back: the harness's row, not theirs.
    'user' when taskNotificationLine(message.text) != null =>
      _BackgroundRunNote(text: taskNotificationLine(message.text)!),
    'user' => _UserMessageCard(
      message: message,
      onSaveNote: onSaveNote,
      onPathTap: onPathTap,
      onLinkTap: onLinkTap,
      resolveHostPath: resolveHostPath,
    ),
    'agent' => _AgentMessageBlock(
      message: message,
      onSaveNote: onSaveNote,
      onCopyTurn: onCopyTurn,
      onPathTap: onPathTap,
      onLinkTap: onLinkTap,
      detail: detail,
    ),
    kAgentSwitchNoticeRole => _AgentSwitchDivider(message: message),
    kTranscriptNoticeRole => _TranscriptNote(text: message.text),
    'error' => _ErrorMessageCard(message: message),
    _ => _ToolMessageCard(
      message: message,
      onSaveNote: onSaveNote,
      resolveHostPath: resolveHostPath,
      onPathTap: onPathTap,
      detail: detail,
    ),
  };
}

class _UserMessageCard extends StatelessWidget {
  const _UserMessageCard({
    required this.message,
    required this.onSaveNote,
    required this.onPathTap,
    required this.onLinkTap,
    required this.resolveHostPath,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final PathLinkCallback? onPathTap;
  final ValueChanged<String>? onLinkTap;
  final String? Function(String path)? resolveHostPath;

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
    // Karmashala's own note to the agent is not the person's words.
    final (:preamble, :rest) = splitScratchPreamble(message.text);
    final bubble = LayoutBuilder(
      builder: (context, constraints) => _TurnWithMeta(
        alignEnd: true,
        at: message.at,
        actions: _messageActions(onSaveNote, message.text),
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
    if (preamble == null && !message.queued) return bubble;
    final muted = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
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
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final PathLinkCallback? onPathTap;
  final ValueChanged<String>? onLinkTap;
  final Widget? detail;
  final String Function()? onCopyTurn;

  @override
  Widget build(BuildContext context) {
    final (thinking, cleanText) = splitThinking(
      message.text,
      explicit: message.thinking,
    );
    // Plain text, no bubble and no name row (board N2): the agent's words are
    // the page, and the user's tinted bubbles are what mark the turns.
    return _TurnWithMeta(
      at: message.at,
      actions: _messageActions(onSaveNote, cleanText, copyTurn: onCopyTurn),
      body: Column(
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
          ),
          ?detail,
        ],
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

/// Claude Code's own "[Request interrupted by user…]" lines.
final _interruptionNote = RegExp(r'^\[Request interrupted by user[^\]]*\]$');

/// An interruption, said quietly on the agent's side: a muted line, since
/// the person did not type it.
class _InterruptionNote extends StatelessWidget {
  const _InterruptionNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final words = text.contains('tool use')
        ? 'Interrupted: you stopped the tool call'
        : 'Interrupted by you';
    return Row(
      children: [
        Icon(AppIcons.stopCircle, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            words,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A background run's completion, said quietly under the run's own name.
class _BackgroundRunNote extends StatelessWidget {
  const _BackgroundRunNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.checkCircle, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// What the CLI said about the session — a hook's message, say — in a muted
/// line, since neither the person nor the agent said it.
class _TranscriptNote extends StatelessWidget {
  const _TranscriptNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey('transcript-notice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.info, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A plan the agent asked to carry out, after the person answered: the plan
/// in its words under whether it was approved. A refused plan is the tool's
/// error (Claude's "keep planning").
class _AnsweredPlanCard extends StatelessWidget {
  const _AnsweredPlanCard({required this.tool});

  final ToolActivity tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final approved = !tool.isError;
    final tone = approved ? SemanticColors.of(context).idle : scheme.outline;
    return TranscriptTurnFrame(
      edge: scheme.outlineVariant,
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: Row(
              children: [
                Icon(
                  approved ? AppIcons.checkCircle : AppIcons.listChecks,
                  size: Chrome.iconSmall,
                  color: tone,
                ),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    approved
                        ? 'Plan approved'
                        : 'Plan not approved: kept planning',
                    style: theme.textTheme.labelMedium?.copyWith(color: tone),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.sm),
          MarkdownMessage(tool.proposedPlan!),
        ],
      ),
    );
  }
}

/// The questions the agent asked, after the person answered: each question
/// over the answer it got, or "answered in a message" when none came back
/// here.
class _AnsweredQuestionsCard extends StatelessWidget {
  const _AnsweredQuestionsCard({required this.questions});

  final List<AskedQuestion> questions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TranscriptTurnFrame(
      edge: scheme.outlineVariant,
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: Row(
              children: [
                Icon(
                  AppIcons.question,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Text(
                  questions.length == 1
                      ? 'Asked you a question'
                      : 'Asked you ${questions.length} questions',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final q in questions) ...[
            const SizedBox(height: Insets.sm),
            Text(q.question, style: theme.textTheme.bodyMedium),
            Text(
              q.answer ?? 'Answered in a message',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: q.answer == null ? null : FontWeight.w600,
                color: q.answer == null ? scheme.onSurfaceVariant : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorMessageCard extends StatelessWidget {
  const _ErrorMessageCard({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final failure = semantic.failure;
    return TranscriptTurnFrame(
      fill: semantic.failureSurface,
      edge: failure.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warningCircle, size: Chrome.iconSmall, color: failure),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionContainer.disabled(
                  child: Text(
                    'ERROR',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failure,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  message.text,
                  style: theme.textTheme.bodySmall?.copyWith(color: failure),
                ),
              ],
            ),
          ),
          _CopyButton(text: message.text),
        ],
      ),
    );
  }
}

/// Handed to what hangs under a tool row: set while it stands in for the
/// whole row — an open question card says all the row would.
class ToolRowStandIn extends InheritedWidget {
  const ToolRowStandIn({
    required this.standsIn,
    required super.child,
    super.key,
  });

  final ValueNotifier<bool> standsIn;

  static ValueNotifier<bool>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToolRowStandIn>()?.standsIn;

  @override
  bool updateShouldNotify(ToolRowStandIn oldWidget) =>
      standsIn != oldWidget.standsIn;
}

/// A tool call, and every role this view does not name — a compaction notice,
/// or a role an importer invented, drawn as the agent's.
class _ToolMessageCard extends StatefulWidget {
  const _ToolMessageCard({
    required this.message,
    required this.onSaveNote,
    required this.resolveHostPath,
    required this.onPathTap,
    required this.detail,
  });

  final ChatMessage message;
  final VoidCallback? onSaveNote;
  final String? Function(String path)? resolveHostPath;
  final PathLinkCallback? onPathTap;
  final Widget? detail;

  @override
  State<_ToolMessageCard> createState() => _ToolMessageCardState();
}

class _ToolMessageCardState extends State<_ToolMessageCard> {
  final _standsIn = ValueNotifier(false);

  /// Keeps the detail's state as the row's frame comes and goes around it.
  final _detailKey = GlobalKey();

  @override
  void dispose() {
    _standsIn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    if (detail == null) return _framed(context, null);
    final kept = KeyedSubtree(key: _detailKey, child: detail);
    return ToolRowStandIn(
      standsIn: _standsIn,
      child: ValueListenableBuilder(
        valueListenable: _standsIn,
        builder: (context, standsIn, _) =>
            standsIn ? kept : _framed(context, kept),
      ),
    );
  }

  Widget _framed(BuildContext context, Widget? detail) {
    final message = widget.message;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failure = SemanticColors.of(context).failure;
    final activity = message.tool;
    final isToolError = activity?.isError == true;
    final accent = isToolError ? failure : scheme.tertiary;
    // A tool row's reasoning is only ever the field, never a scan of its text:
    // a tool row's text means `<thinking>` literally when it contains one.
    final thinking = message.role == 'tool' ? message.thinking?.trim() : null;
    final eyebrow =
        activity?.name ??
        switch (message.role) {
          'tool' => 'Tool',
          kCompactionNoticeRole => 'Compacted',
          _ => 'Agent',
        };
    final shown = toolDisplayName(eyebrow);

    return TranscriptTurnFrame(
      fill: theme.brightness == Brightness.dark
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow,
      edge: isToolError ? failure : scheme.outlineVariant,
      clip: true,
      // Tighter vertically than the other roles: a tool row is the most
      // repeated thing in a transcript, so 4px multiplies by every call.
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // An MCP name is wider than a narrow pane; it gives way first.
          _MessageHeader(
            icon: _toolIcon(activity?.name),
            label: shown,
            fullLabel: activity == null ? null : eyebrow,
            color: accent,
            badge: isToolError ? _FailedBadge(color: failure) : null,
            actions: _messageActions(
              widget.onSaveNote,
              activity?.output ?? message.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          if (thinking != null && thinking.isNotEmpty) ...[
            ThinkingAccordion(thinking: thinking),
            const SizedBox(height: Insets.xs),
          ],
          if (activity != null)
            ToolActivityBody(
              activity: activity,
              resolveHostPath: widget.resolveHostPath,
              onPathTap: widget.onPathTap,
            )
          else
            Text(message.text, style: MonoStyles.label.copyWith(height: 1.35)),
          if (message.detail case final folded?)
            _SessionNote(text: folded, label: 'Summary'),
          ?detail,
        ],
      ),
    );
  }
}

class _FailedBadge extends StatelessWidget {
  const _FailedBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        'FAILED',
        // The theme's smallest label rather than a 9pt literal, which ignores
        // a reader who scaled text up.
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
