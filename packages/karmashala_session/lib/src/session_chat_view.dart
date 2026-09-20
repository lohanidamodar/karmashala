/// **Whether one session has a chat view, read rather than assumed**: the
/// format allowlist is wrong per install, so the answer is per session.
library;

/// What the answer was read from — six shapes, because they are six different
/// sentences and a reader has to be able to act on which.
enum ChatViewEvidence {
  /// Nobody has looked. `agentSupportsChatView` is the prior, and it is a
  /// statement about the store *format*, never about this session.
  unread,

  /// Nothing to look for: no CLI session id yet, or the installation is gone.
  /// Read off rows already in hand, so it has no age.
  noSessionRecord,

  /// This agent's store keeps its messages in a form nothing here can open, so
  /// no path can be derived for any session of it. From the registry.
  storeUnreadable,

  /// A transcript file for this session is on disk.
  transcriptOnDisk,

  /// A path was derived for this session and no file is there — the store keeps
  /// the conversation and no readable record of it. Antigravity on Windows.
  transcriptAbsent,

  /// The stores were searched and this session's file was not in them — also
  /// what a CLI that has not written its first turn looks like.
  notLocated,
}

/// One reading of whether a session has a chat view, with its evidence. A value
/// type with real equality: three surfaces watch it.
class SessionChatView {
  /// Nobody has looked yet; [prior] is what the allowlist says about the format.
  const SessionChatView.unread({required this.prior})
    : evidence = ChatViewEvidence.unread,
      path = null,
      checkedAt = null;

  /// An answer. [checkedAt] is null for the ones read off state we already hold
  /// — an age exists exactly where something was looked at.
  const SessionChatView.read(
    this.evidence, {
    required this.prior,
    this.path,
    this.checkedAt,
  });

  final ChatViewEvidence evidence;

  /// What `agentSupportsChatView` said about the store format, kept on every
  /// reading so an unmeasured one can still answer.
  final bool prior;

  /// The transcript file this reading is about, when one was named. Evidence,
  /// not a handle: it is the file that was looked for, existing or not.
  final String? path;

  /// When the disk was looked at, or null when none was.
  final DateTime? checkedAt;

  /// Whether a chat view can be drawn. An unlooked-at or unlocated session
  /// falls back to the prior — the allowlist, and said to be one.
  bool get hasChatView => switch (evidence) {
    ChatViewEvidence.transcriptOnDisk => true,
    ChatViewEvidence.noSessionRecord ||
    ChatViewEvidence.storeUnreadable ||
    ChatViewEvidence.transcriptAbsent => false,
    ChatViewEvidence.unread || ChatViewEvidence.notLocated => prior,
  };

  bool get isMeasured => evidence != ChatViewEvidence.unread;

  /// Whether this refusal will still hold after the agent answers — the
  /// **structural** nothing. A missing id is a gap, and closes on its own.
  bool get keepsNoRecord =>
      evidence == ChatViewEvidence.storeUnreadable ||
      evidence == ChatViewEvidence.transcriptAbsent;

  /// How old the reading is at [now], never negative. Null when nothing was
  /// looked at, which is not the same as "just now".
  Duration? ageAt(DateTime now) {
    final at = checkedAt;
    if (at == null) return null;
    final elapsed = now.difference(at);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// Why this session has, or has not, a chat view — one sentence, in the words
  /// a reader can act on.
  String get reason => switch (evidence) {
    ChatViewEvidence.unread =>
      prior
          ? 'Not looked at yet — this agent’s store format is one this app reads.'
          : 'Not looked at yet — this agent’s store format is not one this app '
                'reads.',
    ChatViewEvidence.noSessionRecord =>
      'This session has no CLI session id yet, so there is nothing to look for.',
    ChatViewEvidence.storeUnreadable =>
      'This agent’s store is unreadable — it keeps its messages in a form this '
          'app cannot open.',
    ChatViewEvidence.transcriptOnDisk =>
      'A transcript for this session is on disk.',
    ChatViewEvidence.transcriptAbsent =>
      'No transcript file for this session — its store keeps the conversation '
          'and no readable record of it.',
    ChatViewEvidence.notLocated =>
      'This session’s transcript was not in the stores searched — it may not '
          'have been written yet.',
  };

  @override
  bool operator ==(Object other) =>
      other is SessionChatView &&
      other.evidence == evidence &&
      other.prior == prior &&
      other.path == path &&
      other.checkedAt == checkedAt;

  @override
  int get hashCode => Object.hash(evidence, prior, path, checkedAt);

  @override
  String toString() =>
      'SessionChatView(${evidence.name}, prior: $prior, path: $path)';
}
