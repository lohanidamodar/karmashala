import 'package:karmashala_git/git.dart';

/// One file a session changed, as **whichever record answered** describes it.
class SessionChangedFile {
  const SessionChangedFile({
    required this.path,
    required this.kind,
    this.hostPath,
    this.movedTo,
  });

  /// The path verbatim, in the source's own spelling: absolute and POSIX for a
  /// WSL agent's record, repository-relative for a checkpoint.
  final String path;

  /// [path] as **this host** spells it, or null when it cannot be expressed
  /// here. Null is "not reachable as written", never "the same as [path]".
  final String? hostPath;

  final FileEditKind kind;

  /// Where the file moved to, when the record named a rename. Null otherwise.
  final String? movedTo;

  /// What to show. The host's spelling when there is one, because that is the
  /// path the user can act on.
  String get display => hostPath ?? path;

  @override
  bool operator ==(Object other) =>
      other is SessionChangedFile &&
      other.path == path &&
      other.hostPath == hostPath &&
      other.kind == kind &&
      other.movedTo == movedTo;

  @override
  int get hashCode => Object.hash(path, hostPath, kind, movedTo);

  @override
  String toString() => 'SessionChangedFile(${kind.name} $display)';
}

/// Which source answered, and whether it had anything to say. Six members: "no
/// files", "could not read" and "keeps no record" are three sentences.
enum SessionChangedFilesOutcome {
  /// A list, out of the agent's own record of its own run.
  fromAgentRecord,

  /// A list, out of this session's checkpoint chain in git.
  fromCheckpoints,

  /// The agent's record was read, and it names no changed file.
  agentRecordNamesNoFile,

  /// The checkpoint chain was read, and it names no changed file.
  checkpointsNameNoFile,

  /// Neither source could answer. [SessionChangedFilesReport.gap] says why the
  /// agent's record did not, and there is no checkpoint to fall back on.
  nothingCanAnswer,

  /// No such session row — it was archived or deleted while the surface opened.
  unknownSession,
}

/// Why the agent's own record did not answer. Orthogonal to the outcome: git
/// can answer while this says the agent keeps no record.
enum SessionRecordGap {
  /// It did answer.
  none,

  /// This agent keeps no machine-readable record of what it changed.
  agentKeepsNoRecord,

  /// It keeps one, and this reading could not be taken.
  recordUnreadable,

  /// The session has not named a CLI conversation yet, so there is no record to
  /// look for. A CLI writes its own id on its first turn, not at launch.
  noConversationYet,
}

/// What one session changed, where the answer came from, and when it was taken.
/// A plain value, so every sentence below can be asserted without a frame.
class SessionChangedFilesReport {
  const SessionChangedFilesReport({
    required this.outcome,
    required this.checkedAt,
    this.files = const [],
    this.gap = SessionRecordGap.none,
    this.detail = '',
    this.agentName = '',
  });

  final List<SessionChangedFile> files;
  final SessionChangedFilesOutcome outcome;
  final SessionRecordGap gap;

  /// Why the agent's record could not be read, in its own words. Empty unless
  /// [gap] is [SessionRecordGap.recordUnreadable].
  final String detail;

  /// What to call the agent. Empty when the session named none.
  final String agentName;

  /// When this reading was taken. Rendered with `describeAge`, because a
  /// reading that is not live must not look live (§19).
  final DateTime checkedAt;

  String get _agent => agentName.isEmpty ? 'This agent' : agentName;

  /// The one sentence the user sees.
  String get headline => switch (outcome) {
    SessionChangedFilesOutcome.unknownSession => 'There is no such session.',
    SessionChangedFilesOutcome.fromAgentRecord =>
      '${_count()}, from $_agent’s own record of this session.',
    SessionChangedFilesOutcome.fromCheckpoints =>
      '${_count()}, from this session’s checkpoints.',
    SessionChangedFilesOutcome.agentRecordNamesNoFile =>
      '$_agent’s record of this session names no changed file.',
    SessionChangedFilesOutcome.checkpointsNameNoFile =>
      'No checkpoint of this session recorded a changed file.',
    SessionChangedFilesOutcome.nothingCanAnswer => switch (gap) {
      SessionRecordGap.agentKeepsNoRecord =>
        '$_agent keeps no record of what it changed, and this session has no '
            'checkpoint — so nothing here can answer.',
      SessionRecordGap.recordUnreadable =>
        '$_agent’s record of this session could not be read'
            '${detail.isEmpty ? '' : ' ($detail)'}, and there is no checkpoint '
            'to fall back on.',
      SessionRecordGap.noConversationYet =>
        'This session has not named a $_agent conversation yet, and there is '
            'no checkpoint to fall back on.',
      SessionRecordGap.none =>
        'Nothing here can answer what this session changed.',
    },
  };

  /// The second line, when the source needs one. Null when it does not.
  String? get caveat => switch (outcome) {
    SessionChangedFilesOutcome.fromCheckpoints ||
    SessionChangedFilesOutcome.checkpointsNameNoFile =>
      '${_whyGit()}A checkpoint is taken when a turn ends, and the first one is '
          'measured against the commit the repository was on — so anything '
          'already uncommitted when this session’s first turn ended is '
          'counted here too. Sessions share the repository; they are not '
          'isolated in worktrees. Paths are relative to the repository.',
    _ => null,
  };

  String _whyGit() => switch (gap) {
    SessionRecordGap.agentKeepsNoRecord =>
      '$_agent keeps no record of what it changed, so git is the only source. ',
    SessionRecordGap.recordUnreadable =>
      '$_agent’s own record could not be read'
          '${detail.isEmpty ? '' : ' ($detail)'}, so git answered instead. ',
    SessionRecordGap.noConversationYet =>
      'This session has not named a $_agent conversation yet, so git answered '
          'instead. ',
    SessionRecordGap.none => '',
  };

  String _count() => '${files.length} file${files.length == 1 ? '' : 's'}';
}
