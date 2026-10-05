import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../domain/attachment_rules.dart';
import '../store/companion_attachment_store.dart';
import '../store/workspace_names.dart';
import 'agent_records.dart';
import 'companion_prompts.dart';
import 'companion_screens.dart';
import 'screen_transcripts.dart';

/// What the server tells a phone about sessions (slice 5c: always, a desktop
/// open or not): the rows in its store — whose lifecycle status it writes —
/// the imported history, the sessions it runs with no row (a box's), what
/// needs a person (the server's own attention), and the screens of the
/// sessions it runs, read and typed into.
///
/// **Only what the server can see for itself.** A file a phone sends is kept
/// here and handed to the agent by path; no delivery stage and no agent
/// record: a phone is told less, never something the server would be
/// guessing.
class SessionsAtRest {
  SessionsAtRest({
    required this.sessions,
    required this.names,
    required this.screens,
    required this.hostName,
    this.agentStatusOf,
    this.attentionOf,
    this.usageLimitOf,
    this.agentIdOf,
    this.imported,
    this.recordOf,
    this.records,
    this.attachments,
    this.attachmentSupportOf,
    this.deliverOverProtocol,
    ScreenTranscripts? transcripts,
    DateTime Function()? clock,
  }) : transcripts = transcripts ?? ScreenTranscripts(clock: clock),
       _now = clock ?? DateTime.now;

  /// Where a file a phone sends is kept on this machine; null refuses one.
  final CompanionAttachmentStore? attachments;

  /// What a file sent to a row's session may be — its agent's declared
  /// support, and whether a path here is one it can open. Null: none may.
  final RemoteAttachmentSupport Function(Session row)? attachmentSupportOf;

  /// Sends a phone's message to a session by the protocol its agent
  /// speaks — resuming it first when nothing runs it — and answers true;
  /// false for a session with no such agent, which is typed into its screen.
  /// Throws [RemoteApiRefusal] in words when it is refused.
  final Future<bool> Function(String sessionId, String text)?
  deliverOverProtocol;

  /// The rows — the server's store, read through the same interface a
  /// client's copy answers.
  final SessionReads sessions;
  final WorkspaceNames names;
  final CompanionScreens screens;

  /// This machine, as a row's whereabouts names it.
  final String hostName;

  /// The status the server keeps for a session row (or an imported id), or
  /// null when it keeps none: what its agent is doing — idle at its prompt,
  /// or mid-turn — and, without [attentionOf], its attention.
  final AgentStatusReport? Function(String sessionId)? agentStatusOf;

  /// What session [String] asks of a person now, as the server's attention
  /// decided it (`needs_approval`, `failed`), or null.
  final String? Function(String sessionId)? attentionOf;

  /// The words for a usage limit session [String] hit, while its inbox item
  /// is unseen.
  final String? Function(String sessionId)? usageLimitOf;

  /// The agent an installation runs, for a row's label.
  final String? Function(String installationId)? agentIdOf;

  /// Imported history still showing (superseded records left out), newest
  /// first; null lists none.
  final List<ImportedSession> Function()? imported;

  /// Where session [String]'s agent keeps its own record on this machine, or
  /// null when it keeps none here — the transcript then falls back to the
  /// screen.
  final FutureOr<AgentRecordLocation?> Function(String sessionId)? recordOf;

  /// Reads those records, remembering each by its file's revision.
  final AgentRecords? records;

  final ScreenTranscripts transcripts;
  final DateTime Function() _now;

  /// Every row that is not archived, newest first, then the imported history,
  /// then every session the server runs that no row names — a box's.
  List<RemoteSessionSnapshot> list() {
    final repositories = names.repositories();
    final rows = sessions.getAll().where((row) => !row.isArchived).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final named = {for (final row in rows) hostSessionIdOf(row.id)};
    return [
      for (final row in rows) _rowSnapshot(row, repositories),
      for (final record in imported?.call() ?? const <ImportedSession>[])
        _importedSnapshot(record, repositories),
      for (final hosted in screens.sessions())
        if (!named.contains(hosted.hostSessionId)) _hostedSnapshot(hosted),
    ];
  }

  /// The row [sessionId], else the imported record, else the hosted session
  /// of that id, else null.
  RemoteSessionSnapshot? byId(String sessionId) {
    final row = sessions.getById(sessionId);
    if (row != null) return _rowSnapshot(row, names.repositories());
    final record = _importedById(sessionId);
    if (record != null) return _importedSnapshot(record, names.repositories());
    final hosted = screens.find(sessionId);
    return hosted == null ? null : _hostedSnapshot(hosted);
  }

  ImportedSession? _importedById(String id) {
    for (final record in imported?.call() ?? const <ImportedSession>[]) {
      if (record.id == id) return record;
    }
    return null;
  }

  /// Why a prompt in [sessionId] cannot be answered from here, in words.
  RemoteApiRefusal notAnswerableHere(String sessionId) =>
      _importedById(sessionId) != null
      ? const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI — answer it in its own '
          'terminal',
        )
      : const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session is not running in this Karmashala server, so its '
          'prompts cannot be answered from here',
        );

  /// The session's transcript: **its agent's own record** (slice 5c) — the
  /// file the agent writes in its store, found on the server's machine
  /// ([recordOf]) and read by the one reader every surface uses — with the
  /// calls still running when its agent is working. Only a session with no
  /// such record (a plain shell, an agent that keeps none here, a box's
  /// session) falls back to its screens.
  Future<RemoteSessionRecord> transcript(String sessionId) async {
    final located = await recordOf?.call(sessionId);
    final records = this.records;
    if (located != null && records != null) {
      final row = sessions.getById(sessionId);
      final reading = await records.read(
        sessionId,
        located,
        attribution: row == null ? null : _attributionOf(row),
      );
      if (reading != null) {
        return (
          page: RemoteTranscriptPage(
            sessionId: sessionId,
            messages: reading.messages,
            cursor: reading.messages.length,
          ),
          activity: _activity(
            sessionId,
            row,
            reading.calls,
            reading.background,
          ),
        );
      }
    }
    return _screenTranscript(sessionId);
  }

  /// A spawned session's user lines carry who asked; the phone shows them
  /// without it, as the desktop does.
  SessionAttribution? _attributionOf(Session row) {
    final parentId = row.parentSessionId;
    if (parentId == null) return null;
    final parent = sessions.getById(parentId);
    return parent == null
        ? null
        : SessionAttribution(sessionId: parent.id, title: parent.title);
  }

  /// What [row]'s agent has in flight: the record's outstanding [calls], only
  /// while the agent is working in a session that has not ended; nothing
  /// otherwise — an answer, not an absence of one. Its [background] runs
  /// whatever the turn is doing: they outlive the turn that started them.
  RemoteSessionActivity _activity(
    String sessionId,
    Session? row,
    List<RemoteActivityCall> calls, [
    List<RemoteBackgroundRun> background = const [],
  ]) {
    final working =
        row != null &&
        agentIsWorking(row.status, agentStatusOf?.call(sessionId)?.status);
    return RemoteSessionActivity(
      sessionId: sessionId,
      observedAt: _now().toUtc(),
      calls: working ? calls : const [],
      background: background,
    );
  }

  /// The fallback: the session's screens as its transcript, and what is in
  /// flight — nothing a screen can name. Only an agent the status says is
  /// mid-turn is "working on something unrecorded"; one at rest at its
  /// prompt is running nothing.
  RemoteSessionRecord _screenTranscript(String sessionId) {
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

  /// Whether the transcript moved, for a phone polling it — one `stat` for a
  /// record-backed session (its file's `(modified, size)`, and, unmoved, what
  /// is in flight from the last read), the output offset for a screen-backed
  /// one (never an activity: the screen is cheap to take again).
  Future<RemoteRecordReading> recordState(String sessionId) async {
    final since = await records?.since(sessionId);
    if (since != null) {
      final calls = since.calls;
      return (
        revision: since.revision,
        activity: calls == null
            ? null
            : _activity(
                sessionId,
                sessions.getById(sessionId),
                calls,
                since.background ?? const [],
              ),
      );
    }
    final offset = screens.outputOffset(_hostIdOf(sessionId));
    return (revision: offset == null ? null : 'output:$offset', activity: null);
  }

  /// Types [text] into the session's PTY. A prompt naming an [attachment] the
  /// phone sent commits that file to [attachments] first and hands the agent
  /// its path in the desktop composer's words — **sent**, not offered: the
  /// phone that sent the file is the person.
  ///
  /// Refused, in words, for imported history (nothing runs to type into) and
  /// while the agent has a prompt open: typed there, the text is lost and its
  /// Enter picks whatever is highlighted.
  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    RemoteAttachmentRef? attachment,
  }) async {
    if (sessions.getById(sessionId) == null &&
        _importedById(sessionId) != null) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session was imported from the CLI — read-only here; continue '
        'it in its own terminal',
      );
    }
    final report = agentStatusOf?.call(sessionId);
    if (report != null && (report.hasOpenPrompt || report.hasOpenQuestion)) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session is waiting on a prompt — answer it first, then send',
      );
    }
    if (attachment == null) {
      await _deliver(sessionId, text);
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
    await _deliver(sessionId, attachmentPromptBody(text, path));
    return RemotePromptDelivery.sent;
  }

  /// Over the agent's protocol when it speaks one, else typed into its
  /// screen.
  Future<void> _deliver(String sessionId, String text) async {
    if (await deliverOverProtocol?.call(sessionId, text) ?? false) return;
    await screens.type(_hostIdOf(sessionId), text);
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
    final agentId = agentIdOf?.call(row.agentInstallationId);
    return RemoteSessionSnapshot(
      sessionId: row.id,
      title: row.title,
      status: row.status.name,
      archived: row.isArchived,
      attention: attentionOf == null
          ? remoteAttentionOf(agent)
          : attentionOf!(row.id),
      // What the agent of a *running* session is doing: a row that ended (or
      // that nothing can see) has no agent activity, only its ending.
      activity: row.status.claimsLive ? agent?.status.name : null,
      repositoryId: row.repositoryId,
      repositoryName: place?.repositoryName,
      createdAt: row.createdAt.toUtc().toIso8601String(),
      agentLabel: [
        agentId == null
            ? 'Agent'
            : AgentRegistry.builtIn.displayNameFor(agentId),
        row.status.name,
      ].join('  ·  '),
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
      usageLimit: usageLimitOf?.call(row.id),
    );
  }

  /// Imported history: read-only here, said outright.
  RemoteSessionSnapshot _importedSnapshot(
    ImportedSession record,
    Map<String, RepositoryPlace> repositories,
  ) {
    final place = repositories[record.repositoryId];
    return RemoteSessionSnapshot(
      sessionId: record.id,
      title: record.displayTitle,
      status: 'imported',
      attention: attentionOf?.call(record.id),
      repositoryId: record.repositoryId,
      repositoryName: place?.repositoryName,
      createdAt: record.createdAt.toUtc().toIso8601String(),
      agentLabel: [
        AgentRegistry.builtIn.displayNameFor(record.cli),
        'imported',
      ].join('  ·  '),
      // The store file's own time — the agent's writing, nothing inferred.
      lastActivityAt: record.updatedAt?.toUtc().toIso8601String(),
      imported: true,
      projectId: place?.projectId,
      projectName: place?.projectName,
      projectPath: place?.projectPath,
      attachments: const RemoteAttachmentSupport.refused(
        'This is imported history, read-only here — continue it in its own '
        'terminal to attach anything.',
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
