import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../../../core/data/data_client.dart';

final _log = AppLogger.named('sessions.data');

/// Sends [write] without waiting for it: the copy already has it, and a
/// refusal is logged — the copy is then read again whole by the client.
void _send(Future<Object?> write, String what) => unawaited(
  write.then<void>(
    (_) {},
    onError: (Object error) => _log.warning('The server refused $what: $error'),
  ),
);

/// The sessions as the server keeps them: read at once from this app's copy
/// — in the table's orders, through the same [SessionReads] the server
/// answers from its store — and written through the server. Each write lands
/// in the copy the moment it is asked, by the rule the server applies
/// ([SessionPatch]), and the server's answer replaces it; the server may say
/// otherwise (a status it records itself), and its word wins.
///
/// The `void` writes do not wait for the server; the `Future` ones do, for a
/// caller whose next step needs the row to be there — a pane opened on the
/// host after its row is created.
class SessionsData extends SessionRowsIndex {
  SessionsData(DataClient client)
    : _client = client,
      super(() => client.sessions.view, () => client.sessions.version);

  final DataClient _client;

  /// Whether the server has answered: before it, no row is known.
  bool get isPrimed => _client.sessions.isPrimed;

  /// Fires after any row changed — here or anywhere else.
  Stream<void> get changes => _client.sessions.changes;

  /// The checkouts [sessionId] spans, the primary first.
  List<SessionRepositoryLink> linksFor(String sessionId) =>
      _client.sessionLinks[sessionId] ?? const [];

  // Writes.

  /// Records [session], its repository its primary checkout and each of
  /// [repositories] beside it; completes once the server has it.
  Future<Session> create(
    Session session, {
    List<String> repositories = const [],
  }) {
    _client.sessions.setLocal(session.id, session);
    _client.sessionLinks.setLocal(
      session.id,
      orderedLinks([
        SessionRepositoryLink(
          repositoryId: session.repositoryId,
          role: SessionRepositoryRole.primary,
        ),
        for (final id in repositories)
          if (id != session.repositoryId)
            SessionRepositoryLink(
              repositoryId: id,
              role: SessionRepositoryRole.additional,
            ),
      ]),
    );
    return _client.write(
      SessionCreate(session, repositories: repositories),
      domain: DataDomain.sessions,
    );
  }

  /// [create], not waiting for the server.
  void insert(Session session) =>
      _send(create(session), 'session ${session.id}');

  /// Writes the columns [patch] names; completes with the row as the server
  /// now holds it.
  Future<Session> edit(String id, SessionPatch patch) {
    final row = _client.sessions[id];
    if (row != null) _client.sessions.setLocal(id, patch.applyTo(row));
    return _client.write(SessionEdit(id, patch), domain: DataDomain.sessions);
  }

  void _edit(String id, SessionPatch patch) =>
      _send(edit(id, patch), 'a change to session $id ($patch)');

  /// Renames [id]. [byUser] records that the *user* chose this name, which
  /// is what stops the CLI rename sync ever replacing it.
  void updateTitle(String id, String title, {bool byUser = false}) =>
      _edit(id, SessionPatch.rename(title, byUser: byUser));

  void updateStatus(String id, SessionStatus status) =>
      _edit(id, SessionPatch.status(status));

  void updatePaneId(String id, String? paneId) =>
      _edit(id, SessionPatch.pane(paneId));

  /// Its worktree deleted; archived or not, it stays as it was.
  void markWorktreeRemoved(String id, DateTime at) =>
      _edit(id, SessionPatch.worktreeDeleted(at));

  void markArchived(String id, DateTime at) =>
      _edit(id, SessionPatch.archive(at));

  /// Whether session [id]'s agent may operate Karmashala — the person's act.
  void setOperatorGranted(String id, bool granted) =>
      _edit(id, SessionPatch.operator(granted: granted));

  void updatePermissionMode(String id, String? mode) =>
      _edit(id, SessionPatch.permissionMode(mode));

  void updateModel(String id, String? modelId) =>
      _edit(id, SessionPatch.model(modelId));

  void updateWorkingDirectory(String id, EnvironmentPath? directory) =>
      _edit(id, SessionPatch.directory(directory));

  void updateExternalSessionId(String id, String externalSessionId) =>
      _edit(id, SessionPatch.attribute(externalSessionId));

  /// Deletes [id] and what is recorded against it.
  void delete(String id) {
    _client.sessions.setLocal(id, null);
    _client.sessionLinks.setLocal(id, null);
    _send(
      _client.write(SessionDelete(id), domain: DataDomain.sessions),
      'the delete of session $id',
    );
  }

  /// Deletes [ids] and the imported records [importedIds] as one request,
  /// moving each table of the copy once.
  void deleteMany(
    Iterable<String> ids, {
    Iterable<String> importedIds = const [],
  }) {
    final sessionIds = ids.toList();
    final imported = importedIds.toList();
    if (sessionIds.isEmpty && imported.isEmpty) return;
    _client.sessions.removeLocal(sessionIds);
    _client.sessionLinks.removeLocal(sessionIds);
    _client.imported.removeLocal(imported);
    _send(
      _client.write(
        SessionsDeleteMany(sessionIds: sessionIds, importedIds: imported),
        domain: DataDomain.sessions,
      ),
      'the delete of ${sessionIds.length + imported.length} sessions',
    );
  }

  /// Archives [ids] and their ended descendants as one request, answered with
  /// what the server did — a live session is left and named.
  Future<SessionsArchived> archive(Iterable<String> ids) => _client.write(
    SessionsArchive(ids.toList()),
    domain: DataDomain.sessions,
  );

  /// Shows [ids] and their archived descendants again, as one request.
  Future<SessionsArchived> unarchive(Iterable<String> ids) => _client.write(
    SessionsUnarchive(ids.toList()),
    domain: DataDomain.sessions,
  );

  /// Adds a checkout to [sessionId]; refused for another project's.
  Future<List<SessionRepositoryLink>> link(
    String sessionId,
    String repositoryId,
  ) => _client.write(
    SessionLinkAdd(sessionId: sessionId, repositoryId: repositoryId),
    domain: DataDomain.sessions,
  );

  /// Takes a checkout off [sessionId]; the primary stays.
  Future<List<SessionRepositoryLink>> unlink(
    String sessionId,
    String repositoryId,
  ) {
    final links = linksFor(sessionId);
    _client.sessionLinks.setLocal(sessionId, [
      for (final link in links)
        if (link.isPrimary || link.repositoryId != repositoryId) link,
    ]);
    return _client.write(
      SessionLinkRemove(sessionId: sessionId, repositoryId: repositoryId),
      domain: DataDomain.sessions,
    );
  }

  /// Completes once every write sent so far is answered.
  Future<void> settled() => _client.settled();
}

/// The CLI conversations imported as history, as the server keeps them: a
/// conversation a session row records is hidden from every list here
/// ([visibleImported]) and never deleted.
class ImportedSessionsData {
  ImportedSessionsData(this._client, this._sessions);

  final DataClient _client;
  final SessionsData _sessions;
  List<ImportedSession>? _visible;
  (int, int)? _visibleAt;

  Stream<void> get changes => _client.imported.changes;

  /// What is still showing as history, most recently updated first.
  List<ImportedSession> _shown() {
    final at = (_client.imported.version, _client.sessions.version);
    if (_visible == null || at != _visibleAt) {
      _visibleAt = at;
      _visible = List.unmodifiable(
        visibleImported(
          _client.imported.values,
          _sessions.heldExternalSessionIds(),
        ),
      );
    }
    return _visible!;
  }

  /// The native row that took conversation [externalId] over, or null.
  String? supersedingSessionId(String externalId) =>
      supersedingSessionIdIn(_sessions, externalId);

  ImportedSession? getById(String id) => _client.imported[id];

  ImportedSession? getByExternal(String cli, String externalId) {
    for (final row in _client.imported.values) {
      if (row.cli == cli && row.externalId == externalId) return row;
    }
    return null;
  }

  List<ImportedSession> getAll() => [..._shown()];

  Map<String, String> repositoryIdsById() => {
    for (final row in _shown()) row.id: row.repositoryId,
  };

  int countByRepositories(Iterable<String> repositoryIds) {
    final ids = repositoryIds.toSet();
    return _shown().where((row) => ids.contains(row.repositoryId)).length;
  }

  List<ImportedSession> getByRepository(String repositoryId) => [
    for (final row in _shown())
      if (row.repositoryId == repositoryId) row,
  ];

  /// Imports [session] unless it is already imported or a row represents it
  /// — answered from the copy by the server's own rule ([mayImport]), and
  /// sent behind it: true when the record is now being written.
  bool insertIfAbsent(ImportedSession session) {
    if (!mayImport(
      session,
      existing: getByExternal(session.cli, session.externalId),
      superseded: supersedingSessionId(session.externalId) != null,
    )) {
      return false;
    }
    _client.imported.setLocal(session.id, session);
    _send(
      _client.write(ImportedAdd(session), domain: DataDomain.sessions),
      'the import of ${session.externalId}',
    );
    return true;
  }

  void updateTitle(String id, String title) {
    final row = _client.imported[id];
    if (row != null) _client.imported.setLocal(id, row.copyWith(title: title));
    _send(
      _client.write(
        ImportedRename(id: id, title: title),
        domain: DataDomain.sessions,
      ),
      'the rename of imported session $id',
    );
  }

  void delete(String id) {
    _client.imported.setLocal(id, null);
    _send(
      _client.write(ImportedDelete(id), domain: DataDomain.sessions),
      'the delete of imported session $id',
    );
  }
}

/// A session's records at the server: its event log and the relays into it,
/// asked for when needed; its decisions and its recap, kept whole in this
/// app's copy and read at once.
class SessionRecordsData {
  SessionRecordsData(this._client);

  final DataClient _client;

  // Events.

  /// [sessionId]'s event log, in append order.
  Future<List<SessionEvent>> listForSession(String sessionId) async =>
      (await _client.send(SessionEvents(sessionId))).value;

  /// When the newest event of any of [sessionIds] was written, or null.
  Future<DateTime?> lastEventAt(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return null;
    return (await _client.send(SessionEventsLatest(sessionIds))).value;
  }

  /// Appends [event], answered with its sequence number.
  Future<SessionEvent> append(SessionEvent event) async =>
      (await appendAll([event])).single;

  /// Appends [events] in order, each next in its session's log.
  Future<List<SessionEvent>> appendAll(List<SessionEvent> events) =>
      _client.write(SessionEventsAppend(events), domain: DataDomain.sessions);

  // Decisions.

  /// Every decision [sessionId] recorded, oldest first.
  List<DecisionRecord> decisionsFor(String sessionId) => [
    for (final decision in _client.decisions.values)
      if (decision.sessionId == sessionId) decision,
  ]..sort((a, b) => a.sequence.compareTo(b.sequence));

  /// Appends [decision], next in its session's sequence.
  Future<DecisionRecord> appendDecision(DecisionRecord decision) =>
      _client.write(DecisionAppend(decision), domain: DataDomain.sessions);

  // Recaps.

  Stream<void> get recapChanges => _client.recaps.changes;

  SessionRecap? recapFor(String sessionId) => _client.recaps[sessionId];

  void writeRecap(SessionRecap recap) {
    _client.recaps.setLocal(recap.sessionId, recap);
    _send(
      _client.write(RecapWrite(recap), domain: DataDomain.sessions),
      'the recap of session ${recap.sessionId}',
    );
  }

  void dismissRecap(String sessionId) {
    _client.recaps.setLocal(sessionId, null);
    _send(
      _client.write(RecapDismiss(sessionId), domain: DataDomain.sessions),
      'the dismissal of session $sessionId\'s recap',
    );
  }

  // Relays.

  void recordRelay(SessionRelay relay) => _send(
    _client.write(RelayRecord(relay), domain: DataDomain.sessions),
    'a relay into session ${relay.toSessionId}',
  );

  Future<int> relayCount(String from, String to, {required DateTime since}) =>
      _client
          .send(RelayCount(fromSessionId: from, toSessionId: to, since: since))
          .then((reply) => reply.value);

  Future<RelayPage> relaysTo(String to, int limit) =>
      _client.send(RelaysTo(to, limit)).then((reply) => reply.value);
}

/// What sessions left behind, as the server keeps it: kept whole in this
/// app's copy — open ones, resolved ones, and so every ending ever raised.
class FollowUpsData {
  FollowUpsData(this._client);

  final DataClient _client;

  Stream<void> get changes => _client.followUps.changes;

  /// Everything still waiting, newest first, at most [limit].
  List<FollowUp> open({int limit = kOpenFollowUpCap}) =>
      openFollowUps(_client.followUps.values, limit: limit);

  /// `'<sessionId>/<ending>'` for every ending that has ever produced one.
  Set<String> raisedEndings() => {
    for (final followUp in _client.followUps.values) followUp.endingMark,
  };

  /// Raises [followUp] — or null when its session already has one open.
  Future<FollowUp?> raise(FollowUp followUp) =>
      _client.write(FollowUpRaise(followUp), domain: DataDomain.sessions);

  /// Closes the one stored at [id], recording which way it went.
  void resolve(int id, FollowUpResolution resolution, {DateTime? at}) {
    final row = _client.followUps['$id'];
    if (row != null && row.isOpen) {
      _client.followUps.setLocal(
        '$id',
        row.copyWith(
          resolvedAt: (at ?? DateTime.now()).toUtc(),
          resolution: resolution,
        ),
      );
    }
    _send(
      _client.write(
        FollowUpResolve(id, resolution),
        domain: DataDomain.sessions,
      ),
      'the resolution of follow-up $id',
    );
  }
}
