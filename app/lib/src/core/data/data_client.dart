import 'dart:async';
import 'dart:math' as math;

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';

import 'keyed_replica.dart';

/// The domains this app reads through the server.
enum DataDomain {
  notes,
  todos,
  preferences,
  workspace,
  sessions,

  /// Execution environments, saved SSH hosts, trusted host keys.
  environments,

  /// Agent installations and the saved accounts (without credentials).
  agents,
}

/// How this app reaches the server's data now.
enum DataLinkState {
  /// Dialling: the server is starting, or the link closed and is being
  /// redialled. Writes wait for it.
  connecting,

  /// Over the server's socket, every copy primed.
  connected,

  /// The last dial found no server; [DataConnection.reason] says why. Still
  /// redialled in the background when a server may run here at all.
  unavailable,
}

/// [state], and in words why when it is not [DataLinkState.connected].
class DataConnection {
  const DataConnection(this.state, [this.reason]);

  final DataLinkState state;
  final String? reason;

  @override
  String toString() => reason == null ? state.name : '${state.name}: $reason';
}

/// This app's client of the server's data: one link, a copy of each domain
/// the server keeps up to date ([notes], [todos], [preferences], the
/// workspace, [sessions] and their records, [environments] and SSH hosts,
/// [installations] and saved accounts), and the
/// writes, which land in the copy at once and at the server after. Reading
/// never waits; before a server has answered, nothing is known (the copies
/// are not primed) and the app says so rather than guessing.
class DataClient {
  DataClient._(
    this._dial,
    this._connection,
    this._waitForServer, {
    AppLogger? logger,
  }) : _log = logger ?? AppLogger.named('data');

  /// A client with no server to reach — [reason] says why. Reads find
  /// nothing and writes are refused at once. What a container gets that
  /// `main` did not connect.
  factory DataClient.unavailable(String reason, {AppLogger? logger}) =>
      DataClient._(
        null,
        DataConnection(DataLinkState.unavailable, reason),
        Duration.zero,
        logger: logger,
      );

  /// Dials the server with [dial] and, when it answers, primes every copy
  /// before returning. When it does not, the client comes back
  /// [DataLinkState.unavailable] ([unavailableReason], or what the dial
  /// said) and keeps redialling. Writes wait up to [waitForServer] for a
  /// server that is not there, then are refused.
  static Future<DataClient> connect(
    Future<DataEndpoint?> Function() dial, {
    String? unavailableReason,
    Duration waitForServer = const Duration(seconds: 20),
    AppLogger? logger,
  }) async {
    final client = DataClient._(
      dial,
      const DataConnection(
        DataLinkState.connecting,
        'starting the Karmashala server',
      ),
      waitForServer,
      logger: logger,
    );
    if (!await client._dialOnce(unavailableReason)) {
      unawaited(client._redial());
    }
    return client;
  }

  final Future<DataEndpoint?> Function()? _dial;
  final AppLogger _log;
  final Duration _waitForServer;
  DataEndpoint? _endpoint;
  DataConnection _connection;
  StreamSubscription<DataChanges>? _changesSubscription;
  final _connectionChanges = StreamController<DataConnection>.broadcast();
  final _waiting = <_Waiter>[];
  var _closed = false;

  final notes = KeyedReplica<Note>();
  final todos = KeyedReplica<Todo>();
  final preferences = KeyedReplica<String>();

  /// The workspace domain, one copy per table.
  final workspaces = KeyedReplica<Workspace>();
  final projects = KeyedReplica<Project>();
  final repositories = KeyedReplica<Repository>();
  final sections = KeyedReplica<StoredSection>();

  /// The sessions domain: the rows, each one's checkouts (primary first),
  /// the imported history (superseded records too), and the records kept
  /// whole — decisions (by id), recaps (by session) and follow-ups (by id).
  final sessions = KeyedReplica<Session>();
  final sessionLinks = KeyedReplica<List<SessionRepositoryLink>>(_sameLinks);
  final imported = KeyedReplica<ImportedSession>();
  final decisions = KeyedReplica<DecisionRecord>();
  final recaps = KeyedReplica<SessionRecap>();
  final followUps = KeyedReplica<FollowUp>();

  /// Where agents run: the execution environments, the saved SSH hosts (each
  /// with its key's location, which only this client's own read is told)
  /// and the host keys trusted for them, by `host:port`.
  final environments = KeyedReplica<ExecutionEnvironment>();
  final sshHosts = KeyedReplica<SshHost>();
  final knownHosts = KeyedReplica<KnownHostKey>();

  /// The agents: every installation, and the saved accounts **without their
  /// credentials** — a token bundle is asked for, right before a switch.
  final installations = KeyedReplica<AgentInstallation>();
  final claudeAccounts = KeyedReplica<ClaudeAccount>(_sameClaude);
  final codexAccounts = KeyedReplica<CodexAccount>(_sameCodex);

  /// The key [knownHosts] keeps a trusted key under.
  static String knownHostKey(String host, int port) => '$host:$port';

  static bool _sameClaude(ClaudeAccount a, ClaudeAccount b) =>
      a.id == b.id &&
      a.email == b.email &&
      a.organizationUuid == b.organizationUuid &&
      a.organizationName == b.organizationName &&
      a.subscriptionType == b.subscriptionType &&
      a.rateLimitTier == b.rateLimitTier &&
      a.capturedEnvironmentId == b.capturedEnvironmentId &&
      a.capturedAt == b.capturedAt;

  static bool _sameCodex(CodexAccount a, CodexAccount b) =>
      a.id == b.id &&
      a.accountId == b.accountId &&
      a.email == b.email &&
      a.planType == b.planType &&
      a.capturedEnvironmentId == b.capturedEnvironmentId &&
      a.capturedAt == b.capturedAt;

  final _usageRecorded = StreamController<String>.broadcast(sync: true);

  /// The account whose usage history gained rows — written here or by
  /// another client. Nothing of the history is copied: a chart asks for it.
  Stream<String> get usageRecorded => _usageRecorded.stream;

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

  DataConnection get connection => _connection;

  Stream<DataConnection> get connectionChanges => _connectionChanges.stream;

  /// Sends [request] and applies its answer — every row it changed, and
  /// [apply] for what the changes do not say. A refusal other than "no
  /// server" re-reads [domain] (the local write it undoes is gone with it)
  /// and is rethrown.
  Future<R> write<R>(
    DataRequest<R> request, {
    required DataDomain domain,
    void Function(R value, int revision)? apply,
  }) {
    final write = _write(request, domain, apply);
    _inFlight.add(write);
    unawaited(
      write
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _inFlight.remove(write)),
    );
    return write;
  }

  /// Writes sent and not yet answered, which [close] waits for: a setting
  /// changed as the app quits must still reach the server.
  final _inFlight = <Future<Object?>>{};

  /// Completes once every write sent so far is answered (or refused) — for a
  /// caller that wrote without waiting and now needs the server to have it.
  Future<void> settled() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait([
        for (final write in [..._inFlight])
          write.then<void>((_) {}, onError: (Object _) {}),
      ]);
    }
  }

  Future<R> _write<R>(
    DataRequest<R> request,
    DataDomain domain,
    void Function(R value, int revision)? apply,
  ) async {
    try {
      final reply = await send(request);
      apply?.call(reply.value, reply.revision);
      _ownAnswer = true;
      try {
        _onChanges(DataChanges(reply.revision, reply.changes));
      } finally {
        _ownAnswer = false;
      }
      return reply.value;
    } on DataRefused catch (refusal) {
      // A server that is away is re-read whole when it is back.
      if (refusal.code != DataRefusalCode.unavailable) {
        unawaited(resync(domain).catchError((Object _) {}));
      }
      rethrow;
    }
  }

  /// [request] answered by the server. With no server now, it waits up to
  /// the bound for one — in the order asked, ahead of the snapshot a
  /// returning server is read with. Throws [DataRefused].
  Future<DataReply<R>> send<R>(DataRequest<R> request) {
    if (_closed) {
      return Future.error(
        const DataRefused.unavailable('the data client is closed'),
      );
    }
    final endpoint = _endpoint;
    if (endpoint != null) return endpoint.send(request);
    if (_dial == null) return Future.error(_notRunning());
    final answer = Completer<DataReply<R>>();
    late final _Waiter waiter;
    waiter = _Waiter(
      go: (endpoint) => answer.complete(endpoint.send(request)),
      fail: answer.completeError,
      timer: Timer(_waitForServer, () {
        _waiting.remove(waiter);
        answer.completeError(_notRunning());
      }),
    );
    _waiting.add(waiter);
    return answer.future;
  }

  DataRefused _notRunning() => DataRefused.unavailable(
    'the Karmashala server is not running'
    '${_connection.reason == null ? '' : ' (${_connection.reason})'}',
  );

  /// Reads [domain] again, whole — after a write this app made to its rows
  /// some other way (a project deleted clears their filing).
  Future<void> resync(DataDomain domain) async {
    switch (domain) {
      case DataDomain.notes:
        _replaceNotes(await send(const NotesList()));
      case DataDomain.todos:
        _replaceTodos(await send(const TodosList()));
      case DataDomain.preferences:
        _replacePreferences(await send(const PreferencesGet()));
      case DataDomain.workspace:
        _replaceWorkspace(await send(const WorkspaceList()));
      case DataDomain.sessions:
        _replaceSessions(await send(const SessionsList()));
      case DataDomain.environments:
        _replaceEnvironments(await send(const EnvironmentsList()));
      case DataDomain.agents:
        _replaceAgents(await send(const AgentsList()));
    }
  }

  /// Dials now rather than at the next backoff step — the person pressed
  /// Retry, or the server was just started again.
  void retry() {
    if (_closed || _dial == null || _endpoint != null) return;
    _setConnection(
      const DataConnection(
        DataLinkState.connecting,
        'dialling the Karmashala server',
      ),
    );
    final wake = _wake;
    if (_redialing && wake != null && !wake.isCompleted) {
      wake.complete();
    } else {
      unawaited(_redial());
    }
  }

  void _replaceNotes(DataReply<List<Note>> reply) => notes.replaceAll({
    for (final note in reply.value) note.id: note,
  }, reply.revision);

  void _replaceTodos(DataReply<List<Todo>> reply) => todos.replaceAll({
    for (final todo in reply.value) todo.id: todo,
  }, reply.revision);

  void _replacePreferences(DataReply<Map<String, String>> reply) =>
      preferences.replaceAll(reply.value, reply.revision);

  void _replaceWorkspace(DataReply<WorkspaceSnapshot> reply) {
    final WorkspaceSnapshot(
      workspaces: w,
      projects: p,
      repositories: r,
      sections: s,
    ) = reply.value;
    // Projects last: a reader primed by them finds the rest in place.
    workspaces.replaceAll({for (final row in w) row.id: row}, reply.revision);
    repositories.replaceAll({for (final row in r) row.id: row}, reply.revision);
    sections.replaceAll({for (final row in s) row.id: row}, reply.revision);
    projects.replaceAll({for (final row in p) row.id: row}, reply.revision);
  }

  void _replaceEnvironments(DataReply<EnvironmentsSnapshot> reply) {
    final snapshot = reply.value;
    final revision = reply.revision;
    sshHosts.replaceAll({for (final h in snapshot.sshHosts) h.id: h}, revision);
    knownHosts.replaceAll({
      for (final k in snapshot.knownHosts) knownHostKey(k.host, k.port): k,
    }, revision);
    environments.replaceAll({
      for (final e in snapshot.environments) e.id: e,
    }, revision);
  }

  void _replaceAgents(DataReply<AgentsSnapshot> reply) {
    final snapshot = reply.value;
    final revision = reply.revision;
    claudeAccounts.replaceAll({
      for (final a in snapshot.claudeAccounts) a.id: a,
    }, revision);
    codexAccounts.replaceAll({
      for (final a in snapshot.codexAccounts) a.id: a,
    }, revision);
    installations.replaceAll({
      for (final i in snapshot.installations) i.id: i,
    }, revision);
  }

  /// Applies a change to where agents run, or to the agents, the server made
  /// at [revision]. A saved SSH host is told by id alone (its row names where
  /// its key is): one another client wrote is read again whole.
  void applyHostsChange(HostsDomainChange change, int revision) {
    switch (change) {
      case EnvironmentChanged(:final environment):
        environments.applyAt(environment.id, environment, revision);
      case EnvironmentRemoved(:final id):
        environments.applyAt(id, null, revision);
      case SshHostTouched():
        if (!_ownAnswer) {
          unawaited(
            resync(DataDomain.environments).catchError((Object error) {
              _log.warning('Could not re-read the SSH hosts: $error');
            }),
          );
        }
      case SshHostRemoved(:final id):
        sshHosts.applyAt(id, null, revision);
      case KnownHostChanged(:final key):
        knownHosts.applyAt(knownHostKey(key.host, key.port), key, revision);
      case KnownHostRemoved(:final host, :final port):
        knownHosts.applyAt(knownHostKey(host, port), null, revision);
      case InstallationChanged(:final installation):
        installations.applyAt(installation.id, installation, revision);
      case InstallationRemoved(:final id):
        installations.applyAt(id, null, revision);
      case ClaudeAccountChanged(:final account):
        claudeAccounts.applyAt(account.id, account, revision);
      case ClaudeAccountRemoved(:final id):
        claudeAccounts.applyAt(id, null, revision);
      case CodexAccountChanged(:final account):
        codexAccounts.applyAt(account.id, account, revision);
      case CodexAccountRemoved(:final id):
        codexAccounts.applyAt(id, null, revision);
      case UsageRecorded(:final accountKey):
        if (!_usageRecorded.isClosed) _usageRecorded.add(accountKey);
    }
  }

  void _replaceSessions(DataReply<SessionsSnapshot> reply) =>
      _batch(() => _replaceSessionsNow(reply));

  void _replaceSessionsNow(DataReply<SessionsSnapshot> reply) {
    final snapshot = reply.value;
    final revision = reply.revision;
    // The records first and the rows last: a reader primed by the rows finds
    // the rest in place.
    sessionLinks.replaceAll(snapshot.links, revision);
    imported.replaceAll({for (final r in snapshot.imported) r.id: r}, revision);
    decisions.replaceAll({
      for (final d in snapshot.decisions) '${d.id}': d,
    }, revision);
    recaps.replaceAll({
      for (final r in snapshot.recaps) r.sessionId: r,
    }, revision);
    followUps.replaceAll({
      for (final f in snapshot.followUps) '${f.id}': f,
    }, revision);
    sessions.replaceAll({for (final s in snapshot.sessions) s.id: s}, revision);
  }

  /// Applies a sessions-domain change the server made at [revision].
  void applySessionChange(
    SessionDomainChange change,
    int revision,
  ) => switch (change) {
    SessionRowChanged(:final session) => sessions.applyAt(
      session.id,
      session,
      revision,
    ),
    SessionRowRemoved(:final id) => sessions.applyAt(id, null, revision),
    SessionLinksChanged(:final sessionId, :final links) => sessionLinks.applyAt(
      sessionId,
      links.isEmpty ? null : links,
      revision,
    ),
    ImportedChanged(:final session) => imported.applyAt(
      session.id,
      session,
      revision,
    ),
    ImportedRemoved(:final id) => imported.applyAt(id, null, revision),
    DecisionRecorded(:final decision) => decisions.applyAt(
      '${decision.id}',
      decision,
      revision,
    ),
    DecisionRemoved(:final id) => decisions.applyAt('$id', null, revision),
    RecapChanged(:final recap) => recaps.applyAt(
      recap.sessionId,
      recap,
      revision,
    ),
    RecapRemoved(:final sessionId) => recaps.applyAt(sessionId, null, revision),
    FollowUpChanged(:final followUp) => followUps.applyAt(
      '${followUp.id}',
      followUp,
      revision,
    ),
  };

  /// Applies a workspace-domain row the server wrote at [revision].
  void applyRow(RowChange change, int revision) => switch (change) {
    WorkspaceChanged(:final workspace) => workspaces.applyAt(
      workspace.id,
      workspace,
      revision,
    ),
    ProjectChanged(:final project) => projects.applyAt(
      project.id,
      project,
      revision,
    ),
    RepositoryChanged(:final repository) => repositories.applyAt(
      repository.id,
      repository,
      revision,
    ),
    SectionChanged(:final section) => sections.applyAt(
      section.id,
      section,
      revision,
    ),
    WorkspaceRemoved(:final id) => workspaces.applyAt(id, null, revision),
    ProjectRemoved(:final id) => projects.applyAt(id, null, revision),
    RepositoryRemoved(:final id) => repositories.applyAt(id, null, revision),
    SectionRemoved(:final id) => sections.applyAt(id, null, revision),
  };

  var _batchDepth = 0;
  var _ownAnswer = false;
  final _batchEnds = StreamController<void>.broadcast(sync: true);

  /// Whether the copies are taking in one batch from the server now: a whole
  /// change batch, or a snapshot. A reader that turns each row into a signal
  /// holds them until [batchEnds], so N rows one write moved wake watchers
  /// once.
  bool get applyingBatch => _batchDepth > 0;

  /// Whether the batch being taken in is the answer to this app's own write —
  /// every row it moved, side effects included — which the writer announces
  /// itself.
  bool get applyingOwnAnswer => _ownAnswer;

  /// Fires, synchronously, when a batch has been taken in whole.
  Stream<void> get batchEnds => _batchEnds.stream;

  void _batch(void Function() apply) {
    _batchDepth++;
    try {
      apply();
    } finally {
      if (--_batchDepth == 0 && !_batchEnds.isClosed) _batchEnds.add(null);
    }
  }

  void _onChanges(DataChanges batch) => _batch(() => _applyChanges(batch));

  void _applyChanges(DataChanges batch) {
    for (final change in batch.changes) {
      switch (change) {
        case NoteChanged(:final note):
          notes.applyAt(note.id, note, batch.revision);
        case NoteRemoved(:final id):
          notes.applyAt(id, null, batch.revision);
        case TodoChanged(:final todo):
          todos.applyAt(todo.id, todo, batch.revision);
        case TodoRemoved(:final id):
          todos.applyAt(id, null, batch.revision);
        case PreferenceChanged(:final key, :final value):
          preferences.applyAt(key, value, batch.revision);
        case final RowChange row:
          applyRow(row, batch.revision);
        case final SessionDomainChange change:
          applySessionChange(change, batch.revision);
        case final HostsDomainChange change:
          applyHostsChange(change, batch.revision);
      }
    }
  }

  Future<void> _attach(DataEndpoint endpoint) async {
    unawaited(_changesSubscription?.cancel());
    _changesSubscription = endpoint.changes.listen(_onChanges);
    await endpoint.send(const DataSubscribe());
    _endpoint = endpoint;
    unawaited(endpoint.done.then((_) => _lost(endpoint)));
    // Writes that waited go first, in the order they were made; the
    // snapshot after them then includes them.
    final waiting = [..._waiting];
    _waiting.clear();
    for (final waiter in waiting) {
      waiter.timer.cancel();
      waiter.go(endpoint);
    }
    final snapshot = await Future.wait([
      endpoint.send(const NotesList()),
      endpoint.send(const TodosList()),
      endpoint.send(const PreferencesGet()),
      endpoint.send(const WorkspaceList()),
      endpoint.send(const SessionsList()),
      endpoint.send(const EnvironmentsList()),
      endpoint.send(const AgentsList()),
    ]);
    _replaceNotes(snapshot[0] as DataReply<List<Note>>);
    _replaceTodos(snapshot[1] as DataReply<List<Todo>>);
    _replacePreferences(snapshot[2] as DataReply<Map<String, String>>);
    _replaceWorkspace(snapshot[3] as DataReply<WorkspaceSnapshot>);
    // Where agents run and the agents before the sessions that name them.
    _replaceEnvironments(snapshot[5] as DataReply<EnvironmentsSnapshot>);
    _replaceAgents(snapshot[6] as DataReply<AgentsSnapshot>);
    _replaceSessions(snapshot[4] as DataReply<SessionsSnapshot>);
    _setConnection(const DataConnection(DataLinkState.connected));
  }

  /// One dial. True when a server answered and every copy is primed.
  Future<bool> _dialOnce([String? unavailableReason]) async {
    DataEndpoint? endpoint;
    try {
      endpoint = await _dial!();
      if (_closed) {
        await endpoint?.close();
        return false;
      }
      if (endpoint == null) {
        _setConnection(
          DataConnection(
            DataLinkState.unavailable,
            unavailableReason ?? 'nothing answers on its socket',
          ),
        );
        return false;
      }
      await _attach(endpoint);
      return true;
    } on Object catch (error) {
      if (identical(_endpoint, endpoint)) _endpoint = null;
      await endpoint?.close();
      _setConnection(
        DataConnection(
          DataLinkState.unavailable,
          error is DataRefused ? error.message : '$error',
        ),
      );
      return false;
    }
  }

  void _lost(DataEndpoint endpoint) {
    if (_closed || !identical(endpoint, _endpoint)) return;
    _endpoint = null;
    _setConnection(
      const DataConnection(
        DataLinkState.connecting,
        'the link to the Karmashala server closed',
      ),
    );
    _log.warning('The link to the Karmashala server closed; redialling.');
    unawaited(_redial());
  }

  var _redialing = false;
  Completer<void>? _wake;

  static const _backoff = [
    Duration(milliseconds: 250),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  Future<void> _redial() async {
    if (_redialing || _dial == null) return;
    _redialing = true;
    try {
      for (var attempt = 0; !_closed && _endpoint == null; attempt++) {
        await _sleep(_backoff[math.min(attempt, _backoff.length - 1)]);
        if (_closed || _endpoint != null) return;
        if (await _dialOnce()) {
          _log.info('Connected to the Karmashala server.');
          return;
        }
      }
    } finally {
      _redialing = false;
    }
  }

  /// [delay], cut short by [retry] or [close].
  Future<void> _sleep(Duration delay) {
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }

  void _setConnection(DataConnection connection) {
    _connection = connection;
    if (!_connectionChanges.isClosed) _connectionChanges.add(connection);
  }

  /// Closes the link once the writes in flight are answered, or after
  /// [flushWithin]. Writes still waiting for a server are refused now.
  Future<void> close({
    Duration flushWithin = const Duration(seconds: 2),
  }) async {
    if (_closed) return;
    if (_endpoint == null) _failWaiting();
    if (_inFlight.isNotEmpty) {
      await Future.wait([
        for (final write in _inFlight)
          write.then<void>((_) {}, onError: (Object _) {}),
      ]).timeout(flushWithin, onTimeout: () => const []);
    }
    _closed = true;
    _failWaiting();
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    await _changesSubscription?.cancel();
    await _endpoint?.close();
    _endpoint = null;
    // Not awaited: a listener that paused (a provider nobody watches now)
    // would hold the done event, and close would never return.
    unawaited(_connectionChanges.close());
    unawaited(_batchEnds.close());
    unawaited(_usageRecorded.close());
    unawaited(notes.dispose());
    unawaited(todos.dispose());
    unawaited(preferences.dispose());
    for (final replica in <KeyedReplica<Object>>[
      workspaces,
      projects,
      repositories,
      sections,
      sessions,
      sessionLinks,
      imported,
      decisions,
      recaps,
      followUps,
      environments,
      sshHosts,
      knownHosts,
      installations,
      claudeAccounts,
      codexAccounts,
    ]) {
      unawaited(replica.dispose());
    }
  }

  void _failWaiting() {
    final waiting = [..._waiting];
    _waiting.clear();
    for (final waiter in waiting) {
      waiter.timer.cancel();
      waiter.fail(const DataRefused.unavailable('the data client is closed'));
    }
  }
}

/// A request waiting for a server: sent when one attaches, refused when the
/// wait runs out.
class _Waiter {
  _Waiter({required this.go, required this.fail, required this.timer});

  final void Function(DataEndpoint endpoint) go;
  final void Function(Object refusal) fail;
  final Timer timer;
}
