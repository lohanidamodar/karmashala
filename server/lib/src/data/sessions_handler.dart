import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart' show recordIdProblem;
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:agent_cli/read.dart';

/// The sessions domain at the server — the rows, the checkouts each spans,
/// their records (events, decisions, recaps, relays, follow-ups) and the
/// imported CLI history: validates, applies the shared rules
/// (`SessionPatch`, `visibleImported`, …), writes, and says what changed.
///
/// The lifecycle status of a session this server runs is its own to record
/// ([runsSession]): a client's status for one is ignored, not refused, so the
/// rest of its change still lands.
class SessionsHandler {
  SessionsHandler(this._db, this._now, {bool Function(String sessionId)? runs})
    : _runs = runs ?? _never,
      _sessions = SessionDao(_db),
      _links = SessionRepositoryDao(_db),
      _events = SessionEventDao(_db),
      _decisions = DecisionRecordDao(_db),
      _recaps = SessionRecapDao(_db),
      _relays = SessionRelayDao(_db),
      _followUps = FollowUpDao(_db),
      _imported = ImportedSessionDao(_db),
      _repositories = RepositoryDao(_db),
      _projects = ProjectDao(_db);

  static bool _never(String _) => false;

  final AppDatabase _db;
  final DateTime Function() _now;
  final bool Function(String sessionId) _runs;
  final SessionDao _sessions;
  final SessionRepositoryDao _links;
  final SessionEventDao _events;
  final DecisionRecordDao _decisions;
  final SessionRecapDao _recaps;
  final SessionRelayDao _relays;
  final FollowUpDao _followUps;
  final ImportedSessionDao _imported;
  final RepositoryDao _repositories;
  final ProjectDao _projects;

  /// Whether this server runs [sessionId] now, so records its lifecycle.
  bool runsSession(String sessionId) => _runs(sessionId);

  SessionsSnapshot list() => SessionsSnapshot(
    sessions: _sessions.getAll(),
    links: _links.all(),
    imported: _imported.everything(),
    decisions: _decisions.all(),
    recaps: _recaps.all(),
    followUps: _followUps.all(),
  );

  // Rows.

  Session create(SessionCreate request, List<DataChange> changes) {
    var session = request.session;
    // A placeholder is nobody's name: the agent may still give it one.
    if (session.titleByUser && isPlaceholderSessionTitle(session.title)) {
      session = session.copyWith(titleByUser: false);
    }
    final problem = recordIdProblem(session.id);
    if (problem != null) throw DataRefused.invalid('sessions.create: $problem');
    if (_sessions.getById(session.id) != null) {
      throw DataRefused.invalid('a session with id ${session.id} exists');
    }
    final titleProblem = sessionTitleProblem(session.title);
    if (titleProblem != null) throw DataRefused.invalid(titleProblem);
    final primary = _repository(session.repositoryId);
    final known = _db.query('SELECT 1 FROM agent_installations WHERE id = ?;', [
      session.agentInstallationId,
    ]);
    if (known.isEmpty) {
      throw DataRefused.notFound(
        'no agent installation with id ${session.agentInstallationId}',
      );
    }
    final parent = session.parentSessionId;
    if (parent != null && _sessions.getById(parent) == null) {
      throw DataRefused.notFound('no session with id $parent');
    }
    final extras = [
      for (final id in request.repositories)
        if (id != primary.id) _sameProject(primary.projectId, id),
    ];
    _db.transaction(() {
      _sessions.insert(session);
      _links.link(
        session.id,
        session.repositoryId,
        role: SessionRepositoryRole.primary,
      );
      for (final extra in extras) {
        _links.link(session.id, extra);
      }
    });
    final stored = _sessions.getById(session.id)!;
    changes
      ..add(SessionRowChanged(stored))
      ..add(SessionLinksChanged(session.id, _links.linksFor(session.id)));
    return stored;
  }

  Session edit(SessionEdit request, List<DataChange> changes) {
    final row = _session(request.id);
    var patch = request.patch;
    if (patch.title case final title?) {
      final problem = sessionTitleProblem(title);
      if (problem != null) throw DataRefused.invalid(problem);
    }
    // Ignored, and the row told back even when nothing else moved: the
    // asking copy already shows the status it asked for, and is corrected.
    final overridden = patch.status != null && _runs(row.id);
    if (overridden) patch = patch.withoutStatus();
    final edited = patch.applyTo(row);
    if (edited != row) _sessions.write(edited);
    if (edited != row || overridden) {
      changes.add(SessionRowChanged(_session(row.id)));
    }
    return _session(row.id);
  }

  /// The row and, by the schema's cascades, its events, links, recap and
  /// relays go; its decisions and follow-ups stay — a decision outlives its
  /// origin, and a follow-up resolves a gone session itself.
  DataAck delete(SessionDelete request, List<DataChange> changes) {
    _session(request.id);
    final hadRecap = _recaps.forSession(request.id) != null;
    _sessions.delete(request.id);
    changes
      ..add(SessionRowRemoved(request.id))
      ..add(SessionLinksChanged(request.id, const []));
    if (hadRecap) changes.add(RecapRemoved(request.id));
    return const DataAck();
  }

  /// What deleting [checkoutIds] takes with it, read before the delete: the
  /// sessions on them (and their recaps), the imported history they hold,
  /// and the other sessions' links to them. Applied as changes after.
  List<DataChange> Function() checkoutsGoing(List<String> checkoutIds) {
    final going = checkoutIds.toSet();
    final sessions = [
      for (final id in going) ..._sessions.getByRepository(id).map((s) => s.id),
    ];
    final imported = _imported.idsUnder(going);
    final recaps = [
      for (final id in sessions)
        if (_recaps.forSession(id) != null) id,
    ];
    final linked = <String>{
      for (final entry in _links.all().entries)
        if (!sessions.contains(entry.key) &&
            entry.value.any((link) => going.contains(link.repositoryId)))
          entry.key,
    };
    return () => [
      for (final id in sessions) ...[
        SessionRowRemoved(id),
        SessionLinksChanged(id, const []),
      ],
      for (final id in recaps) RecapRemoved(id),
      for (final id in imported) ImportedRemoved(id),
      for (final id in linked) SessionLinksChanged(id, _links.linksFor(id)),
    ];
  }

  // Checkouts a session spans.

  List<SessionRepositoryLink> link(
    SessionLinkAdd request,
    List<DataChange> changes,
  ) {
    final row = _session(request.sessionId);
    final primary = _repository(row.repositoryId);
    _sameProject(primary.projectId, request.repositoryId);
    final before = _links.linksFor(row.id);
    _links.link(row.id, request.repositoryId);
    return _linksChanged(row.id, before, changes);
  }

  List<SessionRepositoryLink> unlink(
    SessionLinkRemove request,
    List<DataChange> changes,
  ) {
    final row = _session(request.sessionId);
    final before = _links.linksFor(row.id);
    _links.unlink(row.id, request.repositoryId);
    return _linksChanged(row.id, before, changes);
  }

  List<SessionRepositoryLink> _linksChanged(
    String sessionId,
    List<SessionRepositoryLink> before,
    List<DataChange> changes,
  ) {
    final after = _links.linksFor(sessionId);
    if (!_sameLinks(before, after)) {
      changes.add(SessionLinksChanged(sessionId, after));
    }
    return after;
  }

  static bool _sameLinks(
    List<SessionRepositoryLink> a,
    List<SessionRepositoryLink> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Records.

  List<SessionEvent> events(SessionEvents request) =>
      _events.listForSession(request.sessionId);

  DateTime? lastEventAt(SessionEventsLatest request) =>
      _events.lastAt(request.sessionIds);

  List<SessionEvent> appendEvents(SessionEventsAppend request) {
    for (final id in {for (final e in request.events) e.sessionId}) {
      _session(id);
    }
    // Each append numbers itself in its own transaction; the store is
    // synchronous, so nothing falls between them.
    return [for (final event in request.events) _events.append(event)];
  }

  DecisionRecord recordDecision(
    DecisionAppend request,
    List<DataChange> changes,
  ) {
    final decision = request.decision;
    _session(decision.sessionId);
    if (decision.summary.trim().isEmpty) {
      throw const DataRefused.invalid('a decision needs a summary');
    }
    final stored = _decisions.append(decision);
    changes.add(DecisionRecorded(stored));
    return stored;
  }

  SessionRecap writeRecap(RecapWrite request, List<DataChange> changes) {
    _session(request.recap.sessionId);
    _recaps.write(request.recap);
    final stored = _recaps.forSession(request.recap.sessionId)!;
    changes.add(RecapChanged(stored));
    return stored;
  }

  DataAck dismissRecap(RecapDismiss request, List<DataChange> changes) {
    if (_recaps.forSession(request.sessionId) == null) return const DataAck();
    _recaps.delete(request.sessionId);
    changes.add(RecapRemoved(request.sessionId));
    return const DataAck();
  }

  DataAck recordRelay(RelayRecord request) {
    _session(request.relay.fromSessionId);
    _session(request.relay.toSessionId);
    _relays.record(request.relay);
    return const DataAck();
  }

  RelayPage relaysTo(RelaysTo request) {
    final page = _relays.recentTo(request.toSessionId, request.limit);
    return RelayPage(page.relays, page.total);
  }

  int relayCount(RelayCount request) => _relays.countBetween(
    request.fromSessionId,
    request.toSessionId,
    since: request.since,
  );

  // Follow-ups.

  FollowUp? raiseFollowUp(FollowUpRaise request, List<DataChange> changes) {
    final asked = request.followUp;
    final raised = _followUps.raise(
      FollowUp(
        sessionId: asked.sessionId,
        reason: asked.reason,
        ending: asked.ending,
        summary: asked.summary,
        raisedAt: _now(),
      ),
    );
    if (raised != null) changes.add(FollowUpChanged(raised));
    return raised;
  }

  FollowUp? resolveFollowUp(FollowUpResolve request, List<DataChange> changes) {
    final before = _followUps.getById(request.id);
    if (before == null) {
      throw DataRefused.notFound('no follow-up with id ${request.id}');
    }
    if (!before.isOpen) return before;
    _followUps.resolve(request.id, resolution: request.resolution, at: _now());
    final after = _followUps.getById(request.id)!;
    changes.add(FollowUpChanged(after));
    return after;
  }

  // Imported history.

  bool addImported(ImportedAdd request, List<DataChange> changes) {
    final candidate = request.session;
    _repository(candidate.repositoryId);
    final added = _imported.insertIfAbsent(candidate);
    if (added) {
      changes.add(ImportedChanged(_imported.getById(candidate.id)!));
    }
    return added;
  }

  DataAck renameImported(ImportedRename request, List<DataChange> changes) {
    _importedRow(request.id);
    _imported.updateTitle(request.id, request.title);
    changes.add(ImportedChanged(_importedRow(request.id)));
    return const DataAck();
  }

  DataAck deleteImported(ImportedDelete request, List<DataChange> changes) {
    _importedRow(request.id);
    _imported.delete(request.id);
    changes.add(ImportedRemoved(request.id));
    return const DataAck();
  }

  // What the server itself wrote, told to every client.

  /// The rows of [sessionIds] as they now stand — for a write the server made
  /// outside a request (a status it recorded, a session it started).
  List<DataChange> sessionsNow(Iterable<String> sessionIds) => [
    for (final id in sessionIds.toSet())
      if (_sessions.getById(id) case final row?) ...[
        SessionRowChanged(row),
        SessionLinksChanged(id, _links.linksFor(id)),
      ] else
        SessionRowRemoved(id),
  ];

  /// Every imported conversation, for the server's own upkeep.
  List<ImportedSession> allImported() => _imported.getAll();

  ImportedSession _importedRow(String id) =>
      _imported.getById(id) ??
      (throw DataRefused.notFound('no imported session with id $id'));

  Session _session(String id) =>
      _sessions.getById(id) ??
      (throw DataRefused.notFound('no session with id $id'));

  Repository _repository(String id) =>
      _repositories.getById(id) ??
      (throw DataRefused.notFound('no checkout with id $id'));

  /// [repositoryId], which must be a checkout of [projectId]: a session spans
  /// checkouts of one project — unless that project is Scratch, whose
  /// sessions have no project of their own and may reach into any.
  String _sameProject(String projectId, String repositoryId) {
    final repository = _repositories.getById(repositoryId);
    if (repository == null) {
      throw DataRefused.notFound('no checkout with id $repositoryId');
    }
    if (repository.projectId != projectId &&
        !(_projects.getById(projectId)?.isScratch ?? false)) {
      throw const DataRefused.invalid(
        'A session can only span repositories within the same project.',
      );
    }
    return repositoryId;
  }
}
