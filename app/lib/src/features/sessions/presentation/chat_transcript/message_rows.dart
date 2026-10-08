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
    this.turnActions,
    this.place,
    this.prose,
    this.sentencePerLine = false,
  });

  /// How an agent row is weighted in its turn; null draws it plainly.
  final AgentProse? prose;
  final bool sentencePerLine;

  /// What this row's turn may do, and where the row stands in it; either
  /// null offers none of the turn's actions.
  final TranscriptTurnActions? turnActions;
  final _TurnPlace? place;

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
        old.previewBuilder != widget.previewBuilder ||
        old.turnActions != widget.turnActions ||
        old.place != widget.place ||
        old.prose != widget.prose ||
        old.sentencePerLine != widget.sentencePerLine) {
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
        turn: _turnHere(message, ordinal),
        prose: widget.prose,
        sentencePerLine: widget.sentencePerLine,
      ),
    );
  }

  /// The turn's actions this row offers: the person's message that opened
  /// the turn, and each of the agent's messages in it.
  List<_TurnAction> _turnHere(ChatMessage message, int ordinal) {
    final actions = widget.turnActions;
    final place = widget.place;
    if (actions == null || place == null) return const [];
    final user = message.role == 'user';
    if (user && place.start != ordinal) return const [];
    if (!user && message.role != 'agent') return const [];
    return _turnActionsFor(actions: actions, place: place, user: user);
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
    this.turn = const [],
    this.prose,
    this.sentencePerLine = false,
  });
  final ChatMessage message;
  final AgentPlan? previousPlan;
  final AgentProse? prose;
  final bool sentencePerLine;

  /// The turn's actions this row offers.
  final List<_TurnAction> turn;

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
      onCopyTurn: turn.isEmpty ? null : onCopyTurn,
      onPathTap: onPathTap,
      onLinkTap: onLinkTap,
      resolveHostPath: resolveHostPath,
      turn: turn,
    ),
    'agent' => _AgentMessageBlock(
      message: message,
      onSaveNote: onSaveNote,
      onCopyTurn: onCopyTurn,
      onPathTap: onPathTap,
      onLinkTap: onLinkTap,
      detail: detail,
      turn: turn,
      prose: prose,
      sentencePerLine: sentencePerLine,
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
