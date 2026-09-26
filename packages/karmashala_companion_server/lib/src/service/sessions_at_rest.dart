import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../domain/attachment_rules.dart';
import '../store/companion_attachment_store.dart';
import '../store/workspace_names.dart';
import 'companion_prompts.dart';
import 'companion_screens.dart';
import 'screen_transcripts.dart';

/// What the session host tells a phone about sessions while no desktop app is
/// connected: the rows in the shared store — whose lifecycle status this host
/// writes — and the sessions it runs, read and typed into through their
/// screens.
///
/// **Only what the host can see for itself.** Attention and what the agent is
/// doing from the agent status it keeps for the sessions it holds; a file a
/// phone sends, kept here and handed to the agent by path; no delivery stage,
/// no agent record: a phone is told less, never something the host would be
/// guessing.
class SessionsAtRest {
  SessionsAtRest({
    required this.sessions,
    required this.names,
    required this.screens,
    required this.hostName,
    this.agentStatusOf,
    this.attachments,
    this.attachmentSupportOf,
    ScreenTranscripts? transcripts,
    DateTime Function()? clock,
  }) : transcripts = transcripts ?? ScreenTranscripts(clock: clock),
       _now = clock ?? DateTime.now;

  /// Where a file a phone sends is kept on this machine; null refuses one.
  final CompanionAttachmentStore? attachments;

  /// What a file sent to a row's session may be — its agent's declared
  /// support, and whether a path here is one it can open. Null: none may.
  final RemoteAttachmentSupport Function(Session row)? attachmentSupportOf;

  final SessionDao sessions;
  final WorkspaceNames names;
  final CompanionScreens screens;

  /// This machine, as a row's whereabouts names it.
  final String hostName;

  /// The agent status the host keeps for a session row, or null when it keeps
  /// none: the row's attention (`needs_approval`, `failed`) and what its agent
  /// is doing — idle at its prompt, or mid-turn — are read off it.
  final AgentStatusReport? Function(String sessionId)? agentStatusOf;
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

  /// The session's screens as its transcript, and what is in flight: nothing
  /// the host can name, since it reads no agent's record. Only an agent the
  /// host's status says is mid-turn is "working on something unrecorded"; one
  /// at rest at its prompt is running nothing.
  RemoteSessionRecord transcript(String sessionId) {
    final hostId = _hostIdOf(sessionId);
    final page = transcripts.read(sessionId, screens.screenText(hostId));
    final running = screens.find(hostId)?.running ?? false;
    final working =
        agentStatusOf?.call(sessionId)?.status == AgentActivityStatus.working;
    return (
      page: page,
      activity: RemoteSessionActivity(
        sessionId: sessionId,
        observedAt: _now().toUtc(),
        absence: running && working ? RemoteActivityAbsence.noRecord : null,
      ),
    );
  }

  /// What moves when the screen can have: the output offset. The activity is
  /// never answered from here — the transcript is cheap to take again.
  RemoteRecordReading recordState(String sessionId) {
    final offset = screens.outputOffset(_hostIdOf(sessionId));
    return (revision: offset == null ? null : 'output:$offset', activity: null);
  }

  /// Types [text] into the session's PTY. A prompt naming an [attachment] the
  /// phone sent commits that file to [attachments] first and hands the agent
  /// its path in the desktop composer's words — **sent**, not offered: with no
  /// desktop there is no message box for a person to read it in first, and the
  /// phone that sent the file is the person.
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    RemoteAttachmentRef? attachment,
  }) async {
    if (attachment == null) {
      await screens.type(_hostIdOf(sessionId), text);
      return RemotePromptDelivery.sent;
    }
    final store = attachments;
    if (store == null) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'this machine keeps no files sent from a phone',
      );
    }
    final String path;
    try {
      path = (await store.commit(
        attachment.deviceId,
        attachment.uploadId,
      )).path;
    } on AttachmentUploadException catch (failure) {
      throw RemoteApiRefusal(ErrorCode.badRequest, failure.message);
    }
    await screens.type(_hostIdOf(sessionId), attachmentPromptBody(text, path));
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
    final agent = agentStatusOf?.call(row.id);
    return RemoteSessionSnapshot(
      sessionId: row.id,
      title: row.title,
      status: row.status.name,
      archived: row.isArchived,
      attention: remoteAttentionOf(agent),
      activity: agent?.status.name,
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
      attachments:
          attachmentSupportOf?.call(row) ??
          const RemoteAttachmentSupport.refused(
            'This machine keeps no files sent from a phone.',
          ),
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
