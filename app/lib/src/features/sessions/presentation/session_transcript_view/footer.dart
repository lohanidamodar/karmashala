// The footer: the strips, the composer, sending and Stop.

part of '../session_transcript_view.dart';

mixin _TranscriptFooter on ConsumerState<SessionTranscriptView> {
  TextEditingController get _composer;
  StreamController<List<String>> get _dropped;
  ValueNotifier<int> get _filesQueued;
  ValueNotifier<int> get _composerFocus;
  void _say(String message);
  void _showAsk();
  void _backToComposer(String text);
  List<String> _takeQueuedFiles();

  /// The server the agent runs on, for the composer's attachments: browsed in
  /// the environment the session's agent runs in, a WSL or SSH one included.
  PickServer _pickServer() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    final environmentId = session == null
        ? null
        : ref
              .read(agentInstallationsDataProvider)
              .getById(session.agentInstallationId)
              ?.environmentId;
    return ref.read(
      pickServerProvider(environmentId ?? localHostEnvironmentId),
    );
  }

  /// The most of the footer the composer may take; the strips get the rest.
  static const _composerShare = 0.7;

  /// The key of the message last sent and not yet taken, kept so a retry of
  /// the same words is the same request to the server; a new message mints
  /// its own.
  String? _sendKey;
  String? _keyedText;

  Widget? _footer;
  bool? _footerActive;

  /// The strips and the composer, built once per [active]: the same instance
  /// every poll, so a new transcript never rebuilds the box being typed in.
  Widget _footerFor(bool active) {
    if (_footer != null && _footerActive == active) return _footer!;
    _footerActive = active;
    return _footer = _footerBody(active);
  }

  /// Whether Esc stops something now: the turn runs, by the server's status
  /// — with or without a call in flight — or a Stop already pressed waits on
  /// the second that ends the session.
  bool get _stoppable {
    final id = widget.sessionId;
    return ref.read(sessionTurnWorkingProvider(id)) ||
        (ref.read(turnStopsProvider)[id]?.stillWorking ?? false);
  }

  /// **The chat's Stop** — the composer's, the working line's, and Esc. Once
  /// the turn has outlived [kStopEscalationAfter] after a press, the next
  /// ends the session instead, asked first.
  void _stop() {
    final id = widget.sessionId;
    if (ref.read(turnStopsProvider)[id]?.stillWorking ?? false) {
      unawaited(_endSession());
      return;
    }
    ref.read(turnStopsProvider.notifier).pressed(id);
    _interruptTurn();
  }

  Future<void> _endSession() => endSessionFromRow(
    context,
    ref,
    widget.sessionId,
    title:
        ref.read(sessionsDataProvider).getById(widget.sessionId)?.title ??
        'this session',
  );

  Future<void> _send(String text) async {
    // `/operator` first: typing it is the person letting this session operate
    // Karmashala. It is taken off the message; alone, it is the whole act.
    final afterOperator = textAfterOperatorCommand(text);
    if (afterOperator != null) {
      await setOperatorGrant(
        context,
        ref,
        widget.sessionId,
        granted: true,
        confirm: false,
      );
      if (afterOperator.isEmpty) {
        _say('This session may now operate Karmashala.');
        return;
      }
      text = '$kOperatorGrantedNote\n\n$afterOperator';
    }
    if (text != _keyedText) {
      _keyedText = text;
      _sendKey = newSessionInputId();
    }
    final actions = ref.read(sessionActionsProvider);
    await (widget.resumesInBackground
        ? actions.continueInBackground(
            widget.sessionId,
            text,
            requestId: _sendKey,
          )
        : actions.continueSession(widget.sessionId, text, requestId: _sendKey));
    _keyedText = null;
    _sendKey = null;
  }

  /// Stops the running turn the way its CLI's own terminal would: an Esc,
  /// pressed by the server when it offers it, else typed into the agent's
  /// pane. Said, not silent, when nothing runs the session.
  void _interruptTurn() {
    offerToStopChildren(context, ref, widget.sessionId);
    unawaited(
      ref.read(sessionTurnInterruptProvider)(widget.sessionId).then((why) {
        if (why != null) _say(why);
      }),
    );
  }

  /// The snippet library, as the composer's menu lists it.
  List<ComposerSnippet> _snippets() => [
    for (final snippet in ref.read(commandSnippetsProvider))
      ComposerSnippet(label: snippet.label, text: snippet.command),
  ];

  /// The agent's slash commands, as the composer's palette lists them. Only
  /// an ACP agent announces any.
  List<ComposerCommand> _commands() => [
    for (final command in ref.read(sessionCommandsProvider(widget.sessionId)))
      ComposerCommand(
        name: command.name,
        description: command.description,
        hint: command.hint,
      ),
  ];

  /// The strips over the composer. The delivery strip sits on the composer's
  /// channel: its prompt actions send through `continueSession`.
  Widget _footerBody(bool active) {
    // A phone's grants are watched here: the footer is built once.
    Widget composer({required bool prompted}) => Consumer(
      builder: (context, ref, _) {
        final caps = ref.watch(capabilitiesProvider);
        // A session that is not running is resumed to take the message.
        final refusal = !caps.maySend
            ? kPromptNotGranted
            : !active && !caps.mayStart
            ? kStartNotGranted
            : null;
        return MessageComposer(
          controller: _composer,
          // Watched here, not by the view: a turn starting or ending
          // rebuilds the box's buttons and nothing else.
          working: ref.watch(sessionTurnWorkingProvider(widget.sessionId)),
          uncertain: ref.watch(sessionTurnUncertainProvider(widget.sessionId)),
          onStop: _stop,
          // Mode, model and stats are on the pane's status bar (owner,
          // 2026-09-28); switching agent is the composer's (2026-10-03).
          chips: [
            if (caps.switchAgent)
              SwitchAgentControl(sessionId: widget.sessionId),
          ],
          // Read when the menu opens, never watched: the footer is
          // built once, and the library changing must not rebuild it.
          snippets: _snippets,
          commands: _commands,
          // Read when the chips draw, like the commands: never watched.
          imagesGoAsImages: () =>
              ref.read(sessionTakesImagesProvider(widget.sessionId)),
          // Read per paste or attach, like the snippets: never watched.
          server: _pickServer,
          droppedFiles: _dropped.stream,
          takeServerFiles: _takeQueuedFiles,
          serverFilesWaiting: _filesQueued,
          focusRequests: _composerFocus,
          attaches: caps.mayAttach,
          camera: () => devicePhotosFor(context, ref),
          enabled: !prompted && refusal == null,
          hintText:
              refusal ??
              (prompted
                  ? 'Answer the prompt above first'
                  : active
                  // No emoji: the old hint named a 🖼 that is nowhere
                  // in the composer; the attach tooltip does.
                  ? 'Message the agent…'
                  : 'Type to continue this session…'),
          onSend: _send,
        );
      },
    );
    return LayoutBuilder(
      // Watched here, where the column is built: the line takes a share of
      // the room only while it shows, so it cannot thin the strips' at rest.
      builder: (context, box) => Consumer(
        builder: (context, ref, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // What was sent while the turn ran, waiting at the server below
            // the transcript it will join: bounded, it scrolls within what the
            // composer leaves, and may not push the box away.
            Flexible(
              child: Consumer(
                builder: (context, ref, _) => QueuedMessagesStrip(
                  sessionId: widget.sessionId,
                  onBackToComposer: _backToComposer,
                  // One line while the agent asks: its card needs the room.
                  folded: ref.watch(_promptOpenProvider(widget.sessionId)),
                ),
              ),
            ),
            // Directly above the box and outside the scroll, so a long queue
            // never hides the running turn or its Stop.
            PinnedPlanStrip(sessionId: widget.sessionId),
            // Flexible like the queue: with the keyboard up it gives way, and
            // the box stays in sight.
            Flexible(child: BackgroundRunsStrip(sessionId: widget.sessionId)),
            // Gives way like the strips: at a large text size it scrolls
            // rather than push the box away.
            if (ref.watch(stopEscalatedProvider(widget.sessionId)))
              Flexible(
                child: SingleChildScrollView(
                  primary: false,
                  child: StopEscalationLine(
                    onEndSession: () => unawaited(_endSession()),
                  ),
                ),
              ),
            ConstrainedBox(
              // A long draft may not crowd an approval out of sight.
              constraints: BoxConstraints(
                maxHeight: box.maxHeight * _composerShare,
              ),
              child: !widget.holdForPrompt
                  ? composer(prompted: false)
                  : Consumer(
                      builder: (context, ref, _) {
                        // Watched here: the footer is built once.
                        final prompted = ref.watch(
                          _promptOpenProvider(widget.sessionId),
                        );
                        final box = composer(prompted: prompted);
                        if (!prompted) return box;
                        // The held box is the way to what holds it.
                        return Semantics(
                          button: true,
                          label: 'Show the prompt to answer',
                          child: GestureDetector(
                            key: const ValueKey('answer-prompt-above'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _showAsk,
                            child: box,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Esc in the chat's footer: stop the running turn.
class _StopTurnIntent extends Intent {
  const _StopTurnIntent();
}

/// Enabled only while the turn runs, so an idle Esc is not consumed — and
/// never reaches the agent, where a stray one clears or rewinds its input.
class _StopTurnAction extends Action<_StopTurnIntent> {
  _StopTurnAction(this._view);

  final _SessionTranscriptViewState _view;

  @override
  bool isEnabled(_StopTurnIntent intent) => _view.mounted && _view._stoppable;

  @override
  Object? invoke(_StopTurnIntent intent) {
    _view._stop();
    return null;
  }
}
