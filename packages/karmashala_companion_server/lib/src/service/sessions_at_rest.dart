import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../store/workspace_names.dart';
import 'companion_screens.dart';
import 'screen_transcripts.dart';

/// What the session host tells a phone about sessions while no desktop app is
/// connected: the rows in the shared store — whose lifecycle status this host
/// writes — and the sessions it runs, read and typed into through their
/// screens.
///
/// **Only what the host can see for itself.** No attention (the status
/// registry is the app's), no delivery stage, no attachments, no agent
/// record: a phone is told less, never something the host would be guessing.
class SessionsAtRest {
  SessionsAtRest({
    required this.sessions,
    required this.names,
    required this.screens,
    required this.hostName,
    ScreenTranscripts? transcripts,
    DateTime Function()? clock,
  }) : transcripts = transcripts ?? ScreenTranscripts(clock: clock),
       _now = clock ?? DateTime.now;

  final SessionDao sessions;
  final WorkspaceNames names;
  final CompanionScreens screens;

  /// This machine, as a row's whereabouts names it.
  final String hostName;
  final ScreenTranscripts transcripts;
  final DateTime Function() _now;

  /// Every row that is not archived, newest first, then every session the
  /// host runs that no row names — a box's sessions, which have no rows.
  List<RemoteSessionSnapshot> list() {
    final repositories = names.repositories();
    final rows = sessions.getAll().where((row) => !row.isArchived).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final named = {for (final row in rows) hostSessionIdOf(row.id)};
    return [
      for (final row in rows) _rowSnapshot(row, repositories),
      for (final hosted in screens.sessions())
        if (!named.contains(hosted.hostSessionId)) _hostedSnapshot(hosted),
    ];
  }

  /// The row [sessionId], else the hosted session of that id, else null.
  RemoteSessionSnapshot? byId(String sessionId) {
    final row = sessions.getById(sessionId);
    if (row != null) return _rowSnapshot(row, names.repositories());
    final hosted = screens.find(sessionId);
    return hosted == null ? null : _hostedSnapshot(hosted);
  }

  /// The session's screens as its transcript, and that nothing is known to be
  /// in flight: the host reads no agent's record.
  RemoteSessionRecord transcript(String sessionId) {
    final hostId = _hostIdOf(sessionId);
    final page = transcripts.read(sessionId, screens.screenText(hostId));
    final running = screens.find(hostId)?.running ?? false;
    return (
      page: page,
      activity: RemoteSessionActivity(
        sessionId: sessionId,
        observedAt: _now().toUtc(),
        absence: running ? RemoteActivityAbsence.noRecord : null,
      ),
    );
  }

  /// What moves when the screen can have: the output offset. The activity is
  /// never answered from here — the transcript is cheap to take again.
  RemoteRecordReading recordState(String sessionId) {
    final offset = screens.outputOffset(_hostIdOf(sessionId));
    return (revision: offset == null ? null : 'output:$offset', activity: null);
  }

  /// Types [text] into the session's PTY. A prompt with an attachment is the
  /// composer's to offer, and the composer is the app's.
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    RemoteAttachmentRef? attachment,
  }) async {
    if (attachment != null) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'a file is offered through the desktop app, which is not running',
      );
    }
    await screens.type(_hostIdOf(sessionId), text);
    return RemotePromptDelivery.sent;
  }

  /// The host session a phone's id runs as: a row's id maps to its host id,
  /// and a session with no row already is one.
  String _hostIdOf(String sessionId) =>
      screens.find(sessionId) != null ? sessionId : hostSessionIdOf(sessionId);

  RemoteSessionSnapshot _rowSnapshot(
    Session row,
    Map<String, RepositoryPlace> repositories,
  ) {
    final place = repositories[row.repositoryId];
    final hosted = screens.find(hostSessionIdOf(row.id));
    return RemoteSessionSnapshot(
      sessionId: row.id,
      title: row.title,
      status: row.status.name,
      archived: row.isArchived,
      repositoryId: row.repositoryId,
      repositoryName: place?.repositoryName,
      createdAt: row.createdAt.toUtc().toIso8601String(),
      lastActivityAt: row.createdAt.toUtc().toIso8601String(),
      whereabouts: hosted != null && hosted.running
          ? 'running on $hostName'
          : null,
      projectId: place?.projectId,
      projectName: place?.projectName,
      projectPath: place?.projectPath,
      worktree: row.worktree?.path,
    );
  }

  /// A session no row names: its command is the only name this machine has.
  RemoteSessionSnapshot _hostedSnapshot(HostedSessionView hosted) =>
      RemoteSessionSnapshot(
        sessionId: hosted.hostSessionId,
        title: hosted.command.isEmpty ? hosted.hostSessionId : hosted.command,
        status: hosted.running
            ? SessionStatus.running.name
            : (hosted.exitCode ?? 0) == 0
            ? SessionStatus.completed.name
            : SessionStatus.failed.name,
        createdAt: hosted.startedAt.toUtc().toIso8601String(),
        lastActivityAt: hosted.startedAt.toUtc().toIso8601String(),
        whereabouts: 'on $hostName',
      );
}
