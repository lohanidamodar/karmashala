part of 'remote_companion_gateway.dart';

// One session's transcript as this phone assembles it: the first read, the
// live append, and the walk that recovers a gap.
//
// **A page walk finishes only when `hasNewer` reads false.** Every page is
// bounded at both ends, so one answer is not an answer — `_drainNewer` keeps
// asking, and its doc below is where that rule is written down. Re-reading
// the tail instead is correct only while the gap is smaller than a page;
// past that it replaces the conversation with its end.

extension _GatewayTranscript on RemoteCompanionGateway {
  Future<void> _primeTranscript(
    String sessionId,
    MultiStreamController<List<CompanionChatMessage>> controller,
  ) async {
    final state = _transcriptOf(sessionId);
    if (state.loaded) {
      controller.add(state.messages);
      return;
    }
    try {
      await _reloadTranscript(sessionId);
    } on Object catch (error) {
      if (state.listeners.contains(controller)) {
        controller.addError(_asGatewayError(error));
      }
    }
  }

  _TranscriptState _transcriptOf(String sessionId) =>
      _transcripts[sessionId] ??= _TranscriptState();

  Future<void> _reloadTranscript(String sessionId) async {
    final client = _requireClient();
    await _ensureSubscribed(client, sessionId);
    final page = await _mapRefusals(() => client.transcript(sessionId));
    final state = _transcriptOf(sessionId);
    state.messages = List.unmodifiable([
      // Said, not hidden. The host sends the tail of a long conversation
      // because the whole of one does not fit in a frame, and a view that
      // simply began in the middle would read as a transcript that had lost
      // its start rather than one showing its end.
      if (page.omitted > 0)
        CompanionChatMessage(
          role: kCompanionNoticeRole,
          text: '${page.omitted} earlier messages are not loaded — this is '
              'the top of what the phone has. The desktop holds the whole '
              'conversation.',
        ),
      // Which nothing this is, in the phone's words, from the host's fact.
      // Only when there is genuinely nothing: a reason beside turns would be
      // describing a transcript that exists.
      if (page.messages.isEmpty) ?_absenceRow(page.absence),
      for (final message in page.messages)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    state.loaded = true;
    state.stale = false;
    _pushTranscript(state);
  }

  /// The host's reason for an empty transcript, in the phone's own words.
  ///
  /// Null for a nothing nobody accounted for — an older desktop, or a reason
  /// this build has never heard of — which leaves the screen's hedged hint in
  /// place rather than inventing a specific claim.
  CompanionChatMessage? _absenceRow(RemoteTranscriptAbsence? absence) =>
      switch (absence) {
        RemoteTranscriptAbsence.noChatView => const CompanionChatMessage(
          role: kCompanionAbsenceRole,
          // The desktop's own sentence for this session, minus the half a
          // phone cannot act on: it has no terminal to look at.
          text:
              'This agent keeps no transcript this app can read, so there is '
              'no chat view for it — on the desktop or here. Its terminal is '
              'the session, and the desktop is where that lives. Messages you '
              'send from here still reach it.',
        ),
        // The same refusal about a conversation rather than an agent, so it
        // does not say "this agent" about a store whose other sessions read
        // perfectly well.
        RemoteTranscriptAbsence.noTranscriptFile => const CompanionChatMessage(
          role: kCompanionAbsenceRole,
          text:
              'This session\'s store kept the conversation and no transcript '
              'this app can read beside it, so there is no chat view for it — '
              'on the desktop or here. Its terminal is the session, and the '
              'desktop is where that lives. Messages you send from here still '
              'reach it.',
        ),
        null => null,
      };

  void _applyAppended(RemoteTranscriptPage page) {
    final state = _transcripts[page.sessionId];
    if (state == null || !state.loaded || state.stale) return;
    if (page.cursor <= state.cursor) return;
    final needed = page.cursor - state.cursor;
    if (needed > page.messages.length) {
      // A stretch went missing (a reconnect raced the poll): re-read truth.
      _startReload(page.sessionId);
      return;
    }
    final delta = page.messages.sublist(page.messages.length - needed);
    state.messages = List.unmodifiable([
      // A turn arriving is the reason going away: "there is nothing to read
      // here" cannot stand above something to read, whatever the host said
      // when the transcript was still empty.
      for (final message in state.messages)
        if (message.role != kCompanionAbsenceRole) message,
      for (final message in delta)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    _pushTranscript(state);
    // A live page is bounded too, so one is not necessarily all of it.
    if (page.hasNewer) _startDrain(page.sessionId);
  }

  /// Pages forward from what this phone holds until the host says there is
  /// nothing newer, and answers whether it got there.
  ///
  /// **The rule the reconnect path turns on.** A page is bounded, so one answer
  /// is not an answer: recovery is finished when, and only when, `hasNewer`
  /// reads false. Re-reading the tail instead — which is what a reconnect used
  /// to do — is correct only while the gap is smaller than a page; past that it
  /// replaces the conversation with its end and says so in a line the reader
  /// has no reason to connect to the turns that went missing.
  ///
  /// False means the pages stopped joining on to what is held, which is a
  /// transcript that moved under us (a rotated store, a compaction) rather than
  /// a gap. Only a full re-read settles that, and the caller does it.
  Future<bool> _drainNewer(String sessionId) async {
    if (!_draining.add(sessionId)) return true;
    try {
      while (true) {
        final state = _transcripts[sessionId];
        if (state == null || !state.loaded) return false;
        final client = _client;
        if (client == null) return false;
        await _ensureSubscribed(client, sessionId);
        final page = await _mapRefusals(
          () => client.transcript(sessionId, after: state.cursor),
        );
        if (!_appendResumed(sessionId, page)) return false;
        // An older host says nothing here, which decodes as false — and false
        // is what it meant: it answered with the whole remainder.
        if (!page.hasNewer) return true;
      }
    } finally {
      _draining.remove(sessionId);
    }
  }

  /// Appends one resumed page, or answers false when it does not join on.
  ///
  /// Keyed by the id this phone *asked* with, never [RemoteTranscriptPage
  /// .sessionId] — a superseded imported id is answered under the live one, and
  /// the screen is still watching the id it opened.
  bool _appendResumed(String sessionId, RemoteTranscriptPage page) {
    final state = _transcripts[sessionId];
    if (state == null || !state.loaded) return false;
    // The host windows from where it was asked, so a contiguous page opens
    // exactly at the cursor. Anything else is a transcript that shrank.
    if (page.omitted != state.cursor) return false;
    if (page.messages.isEmpty) {
      state.cursor = page.cursor;
      return true;
    }
    state.messages = List.unmodifiable([
      // A turn arriving is the reason going away, as on the live path.
      for (final message in state.messages)
        if (message.role != kCompanionAbsenceRole) message,
      for (final message in page.messages)
        CompanionChatMessage(role: message.role, text: message.text),
    ]);
    state.cursor = page.cursor;
    state.stale = false;
    _pushTranscript(state);
    return true;
  }

  /// Kicks a gap recovery that nothing is waiting on, and swallows nothing.
  void _startDrain(String sessionId) {
    unawaited(
      _drainNewer(sessionId).then(
        (complete) {
          // A page that would not join on is a transcript that moved under us;
          // only a full re-read settles it.
          if (!complete) _startReload(sessionId);
        },
        onError: (Object error) {
          onLog?.call('transcript drain for $sessionId failed: $error');
          _startReload(sessionId);
        },
      ),
    );
  }

  void _startReload(String sessionId) {
    unawaited(
      _reloadTranscript(sessionId).then(
        (_) {},
        onError: (Object error) =>
            onLog?.call('transcript reload failed: $error'),
      ),
    );
  }

  void _pushTranscript(_TranscriptState state) {
    for (final listener in state.listeners.toList()) {
      listener.add(state.messages);
    }
  }
}
