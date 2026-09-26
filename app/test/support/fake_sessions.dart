part of 'fake_data_server.dart';

/// The sessions domain of a [FakeDataServer], in memory: the rows and the
/// checkouts each spans, the imported history, and the records. Each table is
/// shaped like the server's DAO so a test seeds it the way the store is
/// written, and reads back what a client wrote. A write here after a client
/// connected reaches it as the server's own change — a status the daemon
/// recorded, a session a phone started.
///
/// The rules are the shared ones (`SessionPatch`, `visibleImported`,
/// `openFollowUps`, …); the server's own validation is tested in
/// `server/test/data/`, not here.
class FakeSessionRows implements SessionStatusStore {
  FakeSessionRows._(this._server);

  final FakeDataServer _server;
  final _rows = <String, Session>{};
  late final _index = SessionRowsIndex(() => _rows);

  void _put(Session row, List<DataChange> changes) {
    _rows[row.id] = row;
    _index.invalidate();
    changes.add(SessionRowChanged(row));
  }

  void _remove(String id, List<DataChange> changes) {
    _rows.remove(id);
    _index.invalidate();
    changes.add(SessionRowRemoved(id));
  }

  /// Records [session] and links its repository as the primary checkout.
  void insert(Session session) {
    final changes = <DataChange>[];
    _put(session, changes);
    _server.sessionLinks._link(
      session.id,
      session.repositoryId,
      SessionRepositoryRole.primary,
      changes,
    );
    _server._tell(null, changes);
  }

  void insertWithPrimaryRepository(Session session) => insert(session);

  /// [session] as it now stands — any column.
  void put(Session session) {
    final changes = <DataChange>[];
    _put(session, changes);
    _server._tell(null, changes);
  }

  void _patch(String id, SessionPatch patch) {
    final row = _rows[id];
    if (row != null) put(patch.applyTo(row));
  }

  void updateTitle(String id, String title, {bool byUser = false}) =>
      _patch(id, SessionPatch.rename(title, byUser: byUser));
  @override
  void updateStatus(String id, SessionStatus status) =>
      _patch(id, SessionPatch.status(status));
  void updatePaneId(String id, String? paneId) =>
      _patch(id, SessionPatch.pane(paneId));
  void updateView(String id, SessionView view) =>
      _patch(id, SessionPatch.view(view));
  void markArchived(String id, DateTime at) =>
      _patch(id, SessionPatch.archive(at));
  void updatePermissionMode(String id, String? mode) =>
      _patch(id, SessionPatch.permissionMode(mode));
  void updateModel(String id, String? modelId) =>
      _patch(id, SessionPatch.model(modelId));
  void updateWorkingDirectory(String id, EnvironmentPath? directory) =>
      _patch(id, SessionPatch.directory(directory));
  void updateExternalSessionId(String id, String externalSessionId) =>
      _patch(id, SessionPatch.attribute(externalSessionId));

  void delete(String id) {
    final changes = <DataChange>[];
    _server._deleteSession(id, changes);
    _server._tell(null, changes);
  }

  @override
  Session? getById(String id) => _index.getById(id);
  @override
  List<Session> getAll() => _index.getAll();
  @override
  List<Session> getByIds(Iterable<String> ids) => _index.getByIds(ids);
  @override
  List<Session> getByPaneIds(Iterable<String> paneIds) =>
      _index.getByPaneIds(paneIds);
  @override
  Map<String, String> paneSessionIds() => _index.paneSessionIds();
  @override
  Map<String, String> repositoryIdsById() => _index.repositoryIdsById();
  @override
  List<Session> getClaimingLive() => _index.getClaimingLive();
  @override
  List<Session> getAllByExternalSessionId(String externalSessionId) =>
      _index.getAllByExternalSessionId(externalSessionId);
  @override
  Session? getByExternalSessionId(String externalSessionId) =>
      _index.getByExternalSessionId(externalSessionId);
  @override
  Set<String> heldExternalSessionIds({String? excludingSessionId}) =>
      _index.heldExternalSessionIds(excludingSessionId: excludingSessionId);
  @override
  List<Session> getWaitingForTitleSync() => _index.getWaitingForTitleSync();
  @override
  List<Session> getUnattributed() => _index.getUnattributed();
  @override
  ({int sessions, int running}) countsByRepositories(
    Iterable<String> repositoryIds,
  ) => _index.countsByRepositories(repositoryIds);
  @override
  List<Session> getByRepository(String repositoryId) =>
      _index.getByRepository(repositoryId);
  @override
  String? parentOf(String id) => _index.parentOf(id);
  @override
  List<Session> childrenOf(String id) => _index.childrenOf(id);
}

/// The `session_repositories` table of a [FakeDataServer].
class FakeSessionLinks {
  FakeSessionLinks._(this._server);

  final FakeDataServer _server;
  final _links = <String, List<SessionRepositoryLink>>{};

  List<SessionRepositoryLink> linksFor(String sessionId) =>
      orderedLinks(_links[sessionId] ?? const []);

  void link(
    String sessionId,
    String repositoryId, {
    String role = SessionRepositoryRole.additional,
  }) {
    final changes = <DataChange>[];
    _link(sessionId, repositoryId, role, changes);
    _server._tell(null, changes);
  }

  void _link(
    String sessionId,
    String repositoryId,
    String role,
    List<DataChange> changes,
  ) {
    final links = _links[sessionId] ??= [];
    if (links.any((link) => link.repositoryId == repositoryId)) return;
    links.add(SessionRepositoryLink(repositoryId: repositoryId, role: role));
    changes.add(SessionLinksChanged(sessionId, linksFor(sessionId)));
  }

  void _unlink(
    String sessionId,
    String repositoryId,
    List<DataChange> changes,
  ) {
    final links = _links[sessionId];
    if (links == null) return;
    final before = links.length;
    links.removeWhere(
      (link) => link.repositoryId == repositoryId && !link.isPrimary,
    );
    if (links.length != before) {
      changes.add(SessionLinksChanged(sessionId, linksFor(sessionId)));
    }
  }
}

/// The `imported_sessions` table of a [FakeDataServer].
class FakeImportedRows {
  FakeImportedRows._(this._server);

  final FakeDataServer _server;
  final _rows = <String, ImportedSession>{};

  List<ImportedSession> _visible() => visibleImported(
    _rows.values,
    _server.sessionRows.heldExternalSessionIds(),
  );

  ImportedSession? getById(String id) => _rows[id];

  ImportedSession? getByExternal(String cli, String externalId) {
    for (final row in _rows.values) {
      if (row.cli == cli && row.externalId == externalId) return row;
    }
    return null;
  }

  List<ImportedSession> getAll() => _visible();

  List<ImportedSession> getByRepository(String repositoryId) => [
    for (final row in _visible())
      if (row.repositoryId == repositoryId) row,
  ];

  bool isSuperseded(String externalId) =>
      supersedingSessionIdIn(_server.sessionRows, externalId) != null;

  /// Imports [session] unless it is already imported, or a row represents it.
  bool insertIfAbsent(ImportedSession session) {
    final changes = <DataChange>[];
    final added = _add(session, changes);
    _server._tell(null, changes);
    return added;
  }

  bool _add(ImportedSession session, List<DataChange> changes) {
    if (!mayImport(
      session,
      existing: getByExternal(session.cli, session.externalId),
      superseded: isSuperseded(session.externalId),
    )) {
      return false;
    }
    _rows[session.id] = session;
    changes.add(ImportedChanged(session));
    return true;
  }

  void updateTitle(String id, String title) {
    final row = _rows[id];
    if (row == null) return;
    final renamed = _rows[id] = row.copyWith(title: title);
    _server._tell(null, [ImportedChanged(renamed)]);
  }

  void delete(String id) {
    if (_rows.remove(id) == null) return;
    _server._tell(null, [ImportedRemoved(id)]);
  }
}

/// A [FakeDataServer]'s session records: the event logs, decisions, recaps,
/// relays and follow-ups.
class FakeSessionRecords {
  FakeSessionRecords._(this._server);

  final FakeDataServer _server;
  final _events = <String, List<SessionEvent>>{};
  final decisions = <int, DecisionRecord>{};
  final recaps = <String, SessionRecap>{};
  final relays = <SessionRelay>[];
  final followUps = <int, FollowUp>{};
  var _rowIds = 0;

  // Events.

  SessionEvent append(SessionEvent event) {
    final log = _events[event.sessionId] ??= [];
    final stored = event.copyWith(id: ++_rowIds, seq: log.length);
    log.add(stored);
    return stored;
  }

  List<SessionEvent> listForSession(String sessionId) => [
    ...?_events[sessionId],
  ];

  int countForSession(String sessionId) => _events[sessionId]?.length ?? 0;

  DateTime? _lastEventAt(List<String> sessionIds) {
    DateTime? last;
    for (final id in sessionIds) {
      for (final event in _events[id] ?? const <SessionEvent>[]) {
        if (last == null || event.createdAt.isAfter(last)) {
          last = event.createdAt;
        }
      }
    }
    return last;
  }

  // Decisions.

  /// Appends [decision] next in its session's sequence, told to every client.
  DecisionRecord appendDecision(DecisionRecord decision) {
    final changes = <DataChange>[];
    final stored = _appendDecision(decision, changes);
    _server._tell(null, changes);
    return stored;
  }

  DecisionRecord _appendDecision(
    DecisionRecord decision,
    List<DataChange> changes,
  ) {
    final stored = decision.copyWith(
      id: ++_rowIds,
      sequence: decisionsFor(decision.sessionId).length + 1,
    );
    decisions[stored.id!] = stored;
    changes.add(DecisionRecorded(stored));
    return stored;
  }

  List<DecisionRecord> decisionsFor(String sessionId) => [
    for (final d in decisions.values)
      if (d.sessionId == sessionId) d,
  ]..sort((a, b) => a.sequence.compareTo(b.sequence));

  // Recaps.

  void writeRecap(SessionRecap recap) {
    recaps[recap.sessionId] = recap;
    _server._tell(null, [RecapChanged(recap)]);
  }

  SessionRecap? recapFor(String sessionId) => recaps[sessionId];

  // Relays.

  void recordRelay(SessionRelay relay) => relays.add(relay);

  int relayCount(String from, String to, {required DateTime since}) => relays
      .where(
        (r) =>
            r.fromSessionId == from &&
            r.toSessionId == to &&
            !r.at.isBefore(since),
      )
      .length;

  RelayPage relaysTo(String to, int limit) {
    final into = [
      for (final r in relays)
        if (r.toSessionId == to) r,
    ];
    return RelayPage(
      into.length > limit ? into.sublist(into.length - limit) : into,
      into.length,
    );
  }

  // Follow-ups.

  /// Raises [followUp] — null when its session already has one open.
  FollowUp? raise(FollowUp followUp) {
    final changes = <DataChange>[];
    final raised = _raise(followUp, changes);
    _server._tell(null, changes);
    return raised;
  }

  FollowUp? _raise(FollowUp followUp, List<DataChange> changes) {
    if (followUps.values.any(
      (f) => f.isOpen && f.sessionId == followUp.sessionId,
    )) {
      return null;
    }
    final stored = followUp.copyWith(id: ++_rowIds);
    followUps[stored.id!] = stored;
    changes.add(FollowUpChanged(stored));
    return stored;
  }

  List<FollowUp> openFollowUps({int limit = kOpenFollowUpCap}) =>
      _openFollowUps(followUps.values, limit: limit);

  FollowUp? _resolve(
    int id,
    FollowUpResolution resolution,
    DateTime at,
    List<DataChange> changes,
  ) {
    final row = followUps[id];
    if (row == null) throw DataRefused.notFound('no follow-up with id $id');
    if (!row.isOpen) return row;
    final resolved = followUps[id] = row.copyWith(
      resolvedAt: at,
      resolution: resolution,
    );
    changes.add(FollowUpChanged(resolved));
    return resolved;
  }
}

/// [FakeSessionRecords]' event logs, shaped like `SessionEventDao`.
class FakeEventRows {
  const FakeEventRows._(this._records);

  final FakeSessionRecords _records;

  SessionEvent append(SessionEvent event) => _records.append(event);
  List<SessionEvent> listForSession(String sessionId) =>
      _records.listForSession(sessionId);
  int countForSession(String sessionId) => _records.countForSession(sessionId);
}

/// [FakeSessionRecords]' decisions, shaped like `DecisionRecordDao`; an
/// append is told to every client.
class FakeDecisionRows {
  const FakeDecisionRows._(this._records);

  final FakeSessionRecords _records;

  DecisionRecord append(DecisionRecord decision) =>
      _records.appendDecision(decision);
  List<DecisionRecord> forSession(String sessionId) =>
      _records.decisionsFor(sessionId);
  int countForSession(String sessionId) =>
      _records.decisionsFor(sessionId).length;
}

/// [FakeSessionRecords]' recaps, shaped like `SessionRecapDao`.
class FakeRecapRows {
  const FakeRecapRows._(this._records);

  final FakeSessionRecords _records;

  void write(SessionRecap recap) => _records.writeRecap(recap);
  SessionRecap? forSession(String sessionId) => _records.recapFor(sessionId);
  void delete(String sessionId) {
    if (_records.recaps.remove(sessionId) != null) {
      _records._server._tell(null, [RecapRemoved(sessionId)]);
    }
  }
}

/// [FakeSessionRecords]' relays, shaped like `SessionRelayDao`.
class FakeRelayRows {
  const FakeRelayRows._(this._records);

  final FakeSessionRecords _records;

  void record(SessionRelay relay) => _records.recordRelay(relay);
  int countBetween(String from, String to, {required DateTime since}) =>
      _records.relayCount(from, to, since: since);
  ({List<SessionRelay> relays, int total}) recentTo(String to, int limit) {
    final page = _records.relaysTo(to, limit);
    return (relays: page.relays, total: page.total);
  }
}

/// [FakeSessionRecords]' follow-ups, shaped like `FollowUpDao`; each write is
/// told to every client.
class FakeFollowUpRows {
  const FakeFollowUpRows._(this._records);

  final FakeSessionRecords _records;

  FollowUp? raise(FollowUp followUp) => _records.raise(followUp);
  List<FollowUp> open({int limit = kOpenFollowUpCap}) =>
      _records.openFollowUps(limit: limit);
  FollowUp? openForSession(String sessionId) {
    for (final f in _records.followUps.values) {
      if (f.isOpen && f.sessionId == sessionId) return f;
    }
    return null;
  }

  List<FollowUp> all() => [..._records.followUps.values];

  void resolve(
    int id, {
    required FollowUpResolution resolution,
    required DateTime at,
  }) {
    final changes = <DataChange>[];
    _records._resolve(id, resolution, at, changes);
    _records._server._tell(null, changes);
  }

  Set<String> raisedEndings() => {
    for (final f in _records.followUps.values) f.endingMark,
  };
}

List<FollowUp> _openFollowUps(Iterable<FollowUp> all, {required int limit}) =>
    openFollowUps(all, limit: limit);

extension _FakeSessionsHandling on FakeDataServer {
  SessionsSnapshot _sessionsSnapshot() => SessionsSnapshot(
    sessions: sessionRows.getAll(),
    links: {
      for (final id in sessionLinks._links.keys)
        if (sessionLinks.linksFor(id).isNotEmpty) id: sessionLinks.linksFor(id),
    },
    imported: [...importedRows._rows.values],
    decisions: [...sessionRecords.decisions.values],
    recaps: [...sessionRecords.recaps.values],
    followUps: [...sessionRecords.followUps.values],
  );

  Session _sessionOrRefuse(String id) =>
      sessionRows.getById(id) ??
      (throw DataRefused.notFound('no session with id $id'));

  Session _createSession(SessionCreate r, List<DataChange> changes) {
    var session = r.session;
    if (session.titleByUser && isPlaceholderSessionTitle(session.title)) {
      session = session.copyWith(titleByUser: false);
    }
    if (sessionRows.getById(session.id) != null) {
      throw DataRefused.invalid('a session with id ${session.id} exists');
    }
    final problem = sessionTitleProblem(session.title);
    if (problem != null) throw DataRefused.invalid(problem);
    sessionRows._put(session, changes);
    sessionLinks._link(
      session.id,
      session.repositoryId,
      SessionRepositoryRole.primary,
      changes,
    );
    for (final extra in r.repositories) {
      sessionLinks._link(
        session.id,
        extra,
        SessionRepositoryRole.additional,
        changes,
      );
    }
    return session;
  }

  Session _editSession(SessionEdit r, List<DataChange> changes) {
    final row = _sessionOrRefuse(r.id);
    if (r.patch.title case final title?) {
      final problem = sessionTitleProblem(title);
      if (problem != null) throw DataRefused.invalid(problem);
    }
    final overridden = r.patch.status != null && runsSessions.contains(row.id);
    final edited = (overridden ? r.patch.withoutStatus() : r.patch).applyTo(
      row,
    );
    if (edited != row) {
      sessionRows._put(edited, changes);
    } else if (overridden) {
      changes.add(SessionRowChanged(row));
    }
    return edited;
  }

  void _deleteSession(String id, List<DataChange> changes) {
    _sessionOrRefuse(id);
    sessionRows._remove(id, changes);
    if (sessionLinks._links.remove(id) != null) {
      changes.add(SessionLinksChanged(id, const []));
    }
    if (sessionRecords.recaps.remove(id) != null) {
      changes.add(RecapRemoved(id));
    }
    sessionRecords._events.remove(id);
  }

  List<SessionRepositoryLink> _linkSession(
    SessionLinkAdd r,
    List<DataChange> changes,
  ) {
    final row = _sessionOrRefuse(r.sessionId);
    final primary = repositoryRows.getById(row.repositoryId);
    final candidate = repositoryRows.getById(r.repositoryId);
    if (candidate == null) {
      throw DataRefused.notFound('no checkout with id ${r.repositoryId}');
    }
    if (primary == null || candidate.projectId != primary.projectId) {
      throw const DataRefused.invalid(
        'A session can only span repositories within the same project.',
      );
    }
    sessionLinks._link(
      row.id,
      r.repositoryId,
      SessionRepositoryRole.additional,
      changes,
    );
    return sessionLinks.linksFor(row.id);
  }

  Object? _handleSessions(DataRequest<Object?> request, List<DataChange> c) =>
      switch (request) {
        SessionsList() => _sessionsSnapshot(),
        final SessionCreate r => _createSession(r, c),
        final SessionEdit r => _editSession(r, c),
        SessionDelete(:final id) => () {
          _deleteSession(id, c);
          return const DataAck();
        }(),
        final SessionLinkAdd r => _linkSession(r, c),
        final SessionLinkRemove r => () {
          _sessionOrRefuse(r.sessionId);
          sessionLinks._unlink(r.sessionId, r.repositoryId, c);
          return sessionLinks.linksFor(r.sessionId);
        }(),
        SessionEvents(:final sessionId) => sessionRecords.listForSession(
          sessionId,
        ),
        SessionEventsLatest(:final sessionIds) => sessionRecords._lastEventAt(
          sessionIds,
        ),
        SessionEventsAppend(:final events) => () {
          for (final event in events) {
            _sessionOrRefuse(event.sessionId);
          }
          return [for (final event in events) sessionRecords.append(event)];
        }(),
        DecisionAppend(:final decision) => () {
          _sessionOrRefuse(decision.sessionId);
          if (decision.summary.trim().isEmpty) {
            throw const DataRefused.invalid('a decision needs a summary');
          }
          return sessionRecords._appendDecision(decision, c);
        }(),
        RecapWrite(:final recap) => () {
          _sessionOrRefuse(recap.sessionId);
          sessionRecords.recaps[recap.sessionId] = recap;
          c.add(RecapChanged(recap));
          return recap;
        }(),
        RecapDismiss(:final sessionId) => () {
          if (sessionRecords.recaps.remove(sessionId) != null) {
            c.add(RecapRemoved(sessionId));
          }
          return const DataAck();
        }(),
        RelayRecord(:final relay) => () {
          sessionRecords.recordRelay(relay);
          return const DataAck();
        }(),
        RelaysTo(:final toSessionId, :final limit) => sessionRecords.relaysTo(
          toSessionId,
          limit,
        ),
        final RelayCount r => sessionRecords.relayCount(
          r.fromSessionId,
          r.toSessionId,
          since: r.since,
        ),
        FollowUpRaise(:final followUp) => sessionRecords._raise(
          FollowUp(
            sessionId: followUp.sessionId,
            reason: followUp.reason,
            ending: followUp.ending,
            summary: followUp.summary,
            raisedAt: _now(),
          ),
          c,
        ),
        FollowUpResolve(:final id, :final resolution) =>
          sessionRecords._resolve(id, resolution, _now(), c),
        ImportedAdd(:final session) => importedRows._add(session, c),
        ImportedRename(:final id, :final title) => () {
          final row =
              importedRows.getById(id) ??
              (throw DataRefused.notFound('no imported session with id $id'));
          final renamed = importedRows._rows[id] = row.copyWith(title: title);
          c.add(ImportedChanged(renamed));
          return const DataAck();
        }(),
        ImportedDelete(:final id) => () {
          if (importedRows._rows.remove(id) == null) {
            throw DataRefused.notFound('no imported session with id $id');
          }
          c.add(ImportedRemoved(id));
          return const DataAck();
        }(),
        _ => throw StateError('not a sessions request: ${request.kind}'),
      };
}
