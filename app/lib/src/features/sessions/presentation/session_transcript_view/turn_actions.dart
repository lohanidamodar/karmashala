// Each turn's Retry, Edit, Fork and Rewind, and the fork preview's words.

part of '../session_transcript_view.dart';

mixin _TranscriptTurnActions on ConsumerState<SessionTranscriptView> {
  ValueNotifier<int> get _composerFocus;
  void _say(String message);
  void _backToComposer(String text);
  Future<void> _send(String text);

  List<ChatMessage>? _pointsMessages;
  List<Checkpoint>? _pointsChain;
  var _forkPoints = const <int, TurnForkPoints>{};

  /// Each turn's fork targets, matched again only when the conversation or
  /// the checkpoints moved.
  Map<int, TurnForkPoints> _forkPointsFor(
    List<ChatMessage> messages,
    List<Checkpoint> newestFirst,
  ) {
    if (identical(messages, _pointsMessages) &&
        identical(newestFirst, _pointsChain)) {
      return _forkPoints;
    }
    _pointsMessages = messages;
    _pointsChain = newestFirst;
    return _forkPoints = turnForkPoints(
      transcriptTurnStarts(messages),
      newestFirst.reversed.toList(),
    );
  }

  /// What each turn's actions may do here: Retry and Edit only where a
  /// message can be sent, Fork only where the session can be forked; all
  /// three wait while a turn runs.
  TranscriptTurnActions _turnActionsFor(
    List<ChatMessage> messages,
    TranscriptTurn turn, {
    required bool active,
  }) {
    final caps = ref.watch(capabilitiesProvider);
    final canSend = caps.maySend && (active || caps.mayStart);
    final canFork =
        caps.mayStart &&
        !ref
            .read(sessionHandoffServiceProvider)
            .forkPlanFor(widget.sessionId)
            .isRefused;
    final rewindable = ref.watch(sessionRewindableProvider(widget.sessionId));
    // A rewind restores files from the same checkpoints a fork would.
    final chain = canFork || rewindable
        ? ref.watch(sessionCheckpointsProvider(widget.sessionId)).value
        : null;
    final running =
        turn == TranscriptTurn.working || turn == TranscriptTurn.awaitingUser;
    return TranscriptTurnActions(
      onRetry: canSend ? _retry : null,
      onEdit: canSend ? _editAndResend : null,
      onFork: canFork ? _forkFrom : null,
      onRewind: rewindable ? _rewindTo : null,
      busy: running ? 'A turn is running: wait for it to end.' : null,
      forkPoints: chain == null ? const {} : _forkPointsFor(messages, chain),
      noForkPoint: canFork
          ? ref.watch(checkpointSkipReasonProvider(widget.sessionId)) ??
                kNoTurnCheckpoint
          : kNoTurnCheckpoint,
    );
  }

  /// Retry: the person's words again, as a new turn.
  void _retry(String words) => unawaited(
    _send(words).catchError((Object error) {
      _say(error is StateError ? error.message : '$error');
    }),
  );

  /// Edit and resend: the words back in the box, which takes the keyboard.
  void _editAndResend(String words) {
    _backToComposer(words);
    _composerFocus.value++;
  }

  /// Fork from here: the server's preview, the person's yes, then the fork,
  /// which opens the new session.
  Future<void> _forkFrom(TurnForkTarget target) async {
    final forks = ref.read(turnForksProvider);
    String why(Object error) => error is StateError ? error.message : '$error';
    final TurnForkPreview preview;
    try {
      preview = await forks.preview(widget.sessionId, target);
    } on Object catch (error) {
      _say(why(error));
      return;
    }
    if (!mounted) return;
    final go = await showConfirmDialog(
      context,
      title: 'Fork from this turn?',
      message: forkPreviewMessage(preview),
      confirmLabel: 'Fork',
    );
    if (!go || !mounted) return;
    try {
      await forks.fork(widget.sessionId, target);
    } on Object catch (error) {
      _say(why(error));
    }
  }

  /// Rewind to here: the person picks what goes back, the server rewinds,
  /// and where the conversation was cut their words go back in the box.
  Future<void> _rewindTo(TurnRewindTarget target) async {
    final rewinds = ref.read(turnRewindsProvider);
    final choice = await RewindDialog.show(
      context,
      target: target,
      preview: (mode) => rewinds.preview(widget.sessionId, target, mode),
    );
    if (choice == null || !mounted) return;
    try {
      final done = await rewinds.rewind(
        widget.sessionId,
        target,
        choice.mode,
        confirm: choice.confirm,
      );
      if (!mounted) return;
      if (choice.mode.cutsConversation && done.composerText.isNotEmpty) {
        _backToComposer(done.composerText);
        _composerFocus.value++;
      }
      final turns = done.turns;
      _say(
        [
          'Rewound',
          if (choice.mode.cutsConversation && turns != null)
            '$turns turn${turns == 1 ? '' : 's'} undone',
          if (choice.mode.restoresCode)
            '${done.files} file${done.files == 1 ? '' : 's'} restored',
        ].join(' · '),
      );
    } on Object catch (error) {
      _say(error is StateError ? error.message : '$error');
    }
  }
}

/// What a fork from a turn will do, as one paragraph per part: the files in
/// each repository, the conversation, and how the agent continues.
@visibleForTesting
String forkPreviewMessage(TurnForkPreview preview) => [
  for (final files in preview.repositories)
    files.restores
        ? 'The files in ${files.repository} go back to how they were at that '
              'turn. Their state now stays in Checkpoints, so this can be '
              'undone there.'
        : 'The files in ${files.repository} stay as they are. '
                  '${files.reason ?? ''}'
              .trim(),
  if (preview.conversation.isNotEmpty) preview.conversation,
  if (preview.explanation.isNotEmpty) preview.explanation,
].join('\n\n');
