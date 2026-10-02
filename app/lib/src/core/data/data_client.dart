import 'dart:async';
import 'dart:math' as math;

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_comparisons/comparisons.dart'
    show Comparison, sameComparison;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_verification/verification.dart'
    show VerificationRun, sameVerificationHeader;
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart'
    show FlutterAppRegistry;
import 'package:karmashala_git/git.dart'
    show ReviewThread, WorktreeSetup, WorktreeSetupReport;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_remote/remote.dart'
    show PairedDevice, samePairedDevice;
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';

import 'automations_copy.dart';
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

  /// Paired devices (phones), without their keys or push tokens.
  pairings,

  /// Worktree setups and their runs, review threads.
  worktrees,

  /// Command snippets and saved terminal presets.
  snippets,

  /// Automations, their runs and checks, project checks, scheduled resumes.
  automations,

  /// Verification run headers and fan-out comparisons. Checkpoints are
  /// asked for per session, not copied.
  evidence,
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
    this.serverOnThisMachine = true,
    this._redialHoldOff,
  }) : _log = logger ?? AppLogger.named('data');

  /// A client with no server to reach — [reason] says why. Reads find
  /// nothing and writes are refused at once. What a container gets that
  /// `main` did not connect. False [serverOnThisMachine] on a client that
  /// cannot host one, so a missing server is never taken for a local one.
  factory DataClient.unavailable(
    String reason, {
    AppLogger? logger,
    bool serverOnThisMachine = true,
  }) => DataClient._(
    null,
    DataConnection(DataLinkState.unavailable, reason),
    Duration.zero,
    logger: logger,
    serverOnThisMachine: serverOnThisMachine,
  );

  /// Dials the server with [dial] and, when it answers, primes every copy
  /// before returning. When it does not, the client comes back
  /// [DataLinkState.unavailable] ([unavailableReason], or what the dial
  /// said) and keeps redialling. Writes wait up to [waitForServer] for a
  /// server that is not there, then are refused. With [firstDialWithin], it
  /// returns after that long still [DataLinkState.connecting], and the first
  /// dial goes on. When [redialHoldOff] returns a wait, the next redial waits
  /// that long instead of the backoff step; [retry] still dials at once.
  static Future<DataClient> connect(
    Future<DataEndpoint?> Function() dial, {
    String? unavailableReason,
    Duration waitForServer = const Duration(seconds: 20),
    AppLogger? logger,
    bool serverOnThisMachine = true,
    Duration? firstDialWithin,
    Duration? Function()? redialHoldOff,
  }) async {
    final client = DataClient._(
      dial,
      const DataConnection(
        DataLinkState.connecting,
        'starting the Karmashala server',
      ),
      waitForServer,
      logger: logger,
      serverOnThisMachine: serverOnThisMachine,
      redialHoldOff: redialHoldOff,
    );
    client._firstDialing = true;
    final first = client._dialOnce(unavailableReason).then((connected) {
      client._firstDialing = false;
      if (!connected || client._endpoint == null) unawaited(client._redial());
    });
    if (firstDialWithin == null) {
      await first;
    } else {
      await first.timeout(firstDialWithin, onTimeout: () {});
    }
    return client;
  }

  /// While [connect]'s first dial runs, no redial starts beside it.
  var _firstDialing = false;

  final Future<DataEndpoint?> Function()? _dial;
  final Duration? Function()? _redialHoldOff;
  final AppLogger _log;

  /// Whether the server runs on this client's machine, so a path it spells
  /// for its own disk (`files.resolve`'s `localPath`) opens here too. A
  /// server elsewhere hands its files over as bytes.
  final bool serverOnThisMachine;
  final Duration _waitForServer;
  DataEndpoint? _endpoint;
  DataConnection _connection;
  StreamSubscription<DataChanges>? _changesSubscription;
  final _connectionChanges = StreamController<DataConnection>.broadcast();
  final _waiting = <_Waiter>[];
  var _closed = false;

  final notes = KeyedReplica<Note>();
  final todos = KeyedReplica<Todo>();

  /// Automations, the runs worth holding and their checks, origin chains,
  /// project checks, verification switches and the resumes worth holding.
  final automations = AutomationsCopy();
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
  /// credentials** — a token bundle never leaves the server.
  final installations = KeyedReplica<AgentInstallation>();

  /// The ACP agents a person added (ACP design, C2), by row id.
  final acpAgents = KeyedReplica<AcpAgentRow>();
  final claudeAccounts = KeyedReplica<ClaudeAccount>(_sameClaude);
  final codexAccounts = KeyedReplica<CodexAccount>(_sameCodex);

  /// Every agent account's usage as the server last read it, by account key
  /// (`usageAccountKey`): the reading, how its last attempt failed, when it
  /// asks next. The server reads them; this only follows.
  final usageStates = KeyedReplica<AccountUsageState>((a, b) => a.sameAs(b));

  /// The paired devices, **without their keys or push tokens**.
  final devices = KeyedReplica<PairedDevice>(samePairedDevice);

  /// The git side tables: each checkout's worktree setup (by repository id),
  /// every worktree's setup verdict (by `WorktreeSetupReport.key`) and every
  /// review thread with its comments.
  final worktreeSetups = KeyedReplica<WorktreeSetup>();
  final worktreeRuns = KeyedReplica<WorktreeSetupReport>(sameSetupReport);
  final reviewThreads = KeyedReplica<ReviewThread>(sameReviewThread);

  /// The command snippets and the saved terminal presets.
  final snippets = KeyedReplica<CommandSnippet>();
  final presets = KeyedReplica<StoredPreset>();

  /// Every verification run's header (no steps, no evidence rows: those are
  /// asked for), and every fan-out comparison with its candidates.
  final verificationRuns = KeyedReplica<VerificationRun>(
    sameVerificationHeader,
  );
  final comparisons = KeyedReplica<Comparison>(sameComparison);

  final _evidenceChanges = StreamController<EvidenceChange>.broadcast(
    sync: true,
  );

  /// Checkpoints recorded or pruned and runs that gained evidence, here or
  /// by another client — what a view of rows not copied reads again on.
  Stream<EvidenceChange> get evidenceChanges => _evidenceChanges.stream;

  final _gitChanges = StreamController<GitChange>.broadcast(sync: true);

  /// What the server's git work moved — a checkout touched, a worktree
  /// creation's stage, a cleanup sweep — here or by another client. Nothing
  /// of it is copied: a view that shows it asks again.
  Stream<GitChange> get gitChanges => _gitChanges.stream;

  final _fileChanges = StreamController<FileChanged>.broadcast(sync: true);

  /// A path this link watches (`files.watch`) changed on disk. Told to this
  /// client alone; a new link watches nothing until asked again.
  Stream<FileChanged> get fileChanges => _fileChanges.stream;

  final _transcriptChanges = StreamController<TranscriptChanged>.broadcast(
    sync: true,
  );

  /// A transcript this link watches (`sessions.transcript.watch`) moved. Told
  /// to this client alone; a new link watches nothing until asked again.
  Stream<TranscriptChanged> get transcriptChanges => _transcriptChanges.stream;

  /// The terminals the server runs (slice 5a), as its screens read them,
  /// by session id — greeted whole on subscribe, then kept by each change.
  final terminals = <String, TerminalRecord>{};

  final _terminalChanges = StreamController<TerminalChange>.broadcast(
    sync: true,
  );

  /// A server terminal started, moved (title, folder, last command) or
  /// ended, or was forgotten.
  Stream<TerminalChange> get terminalChanges => _terminalChanges.stream;

  /// The modes each session's agent offers (ACP design, C5), by session id,
  /// as last told. In memory only: the agent announces them again on resume.
  final sessionModes = <String, SessionModesChanged>{};

  final _sessionModeChanges = StreamController<SessionModesChanged>.broadcast(
    sync: true,
  );

  /// A session's agent announced or changed its modes.
  Stream<SessionModesChanged> get sessionModeChanges =>
      _sessionModeChanges.stream;

  /// The config options (a model, a flag) each session's agent exposes, by
  /// session id, as last told. In memory only, like [sessionModes].
  final sessionConfigOptions = <String, SessionConfigOptionsChanged>{};

  final _sessionConfigOptionChanges =
      StreamController<SessionConfigOptionsChanged>.broadcast(sync: true);

  /// A session's agent announced or changed its config options.
  Stream<SessionConfigOptionsChanged> get sessionConfigOptionChanges =>
      _sessionConfigOptionChanges.stream;

  /// What each session's agent last reported of its context and cost, by
  /// session id. In memory only, like [sessionModes].
  final sessionUsage = <String, SessionUsageChanged>{};

  final _sessionUsageChanges = StreamController<SessionUsageChanged>.broadcast(
    sync: true,
  );

  /// A session's agent reported its usage.
  Stream<SessionUsageChanged> get sessionUsageChanges =>
      _sessionUsageChanges.stream;

  /// Every session's status the server keeps (slice 5c), by the workspace
  /// row it opens under — greeted whole on subscribe, then kept by each
  /// change.
  final sessionStatuses = <String, SessionStatusEntry>{};

  /// How much of the watch set the server's last cycle reached; null until
  /// it has said.
  WatchCoverage? watchCoverage;

  /// The server's inbox and who is waiting, as last told.
  AttentionSnapshot attention = AttentionSnapshot.empty;

  /// What the forge says about each checkout's branch, as the server's own
  /// delivery poll last read it (slice 5c), by checkout directory — greeted
  /// whole on subscribe, then kept by each `ForgeReadingChanged`.
  final forgeReadings = <EnvironmentPath, PullRequestReading>{};

  final _attentionChanges = StreamController<AttentionChange>.broadcast(
    sync: true,
  );

  /// A status, the watch set's reach, the inbox, agent news or a cue to show
  /// a session — each as the server tells it, after the copy above has it.
  Stream<AttentionChange> get attentionChanges => _attentionChanges.stream;

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

  /// Where each of the server's own SSH connections stands, by host id, as
  /// last told (slice 3a). Absent is idle.
  final sshConnections = <String, SshConnectionState>{};

  final _sshChanges = StreamController<SshChange>.broadcast(sync: true);

  /// The server's SSH connections moving, and the questions they put to a
  /// person opening and closing.
  Stream<SshChange> get sshChanges => _sshChanges.stream;

  /// The names in the server's environment vault, as last told (slice 5a);
  /// null until the server has said. Never a value: the vault is write-only.
  List<EnvVariableName>? envVariables;

  final _envChanges = StreamController<List<EnvVariableName>>.broadcast(
    sync: true,
  );

  /// The vault's names, whole, each time they change.
  Stream<List<EnvVariableName>> get envChanges => _envChanges.stream;

  /// The folders pinned to every file browser, as last told. A new link
  /// starts from none: the server greets it only when something is pinned.
  List<QuickAccessPin> quickAccessPins = const [];

  final _quickAccessChanges = StreamController<List<QuickAccessPin>>.broadcast(
    sync: true,
  );

  /// The pins, whole, each time they change — here or on another client.
  Stream<List<QuickAccessPin>> get quickAccessChanges =>
      _quickAccessChanges.stream;

  void _setQuickAccess(List<QuickAccessPin> pins) {
    quickAccessPins = List.unmodifiable(pins);
    if (!_quickAccessChanges.isClosed) _quickAccessChanges.add(pins);
  }

  /// The app stores as the server holds them, as last told; null until the
  /// server has said. Never a credential: summaries only.
  StoresView? storesView;

  final _storesChanges = StreamController<StoresView>.broadcast(sync: true);

  /// The stores' view, whole, each time it changes.
  Stream<StoresView> get storesChanges => _storesChanges.stream;

  final _storesProgress = StreamController<({int done, int total})>.broadcast(
    sync: true,
  );

  /// How far a refresh under way has got, once per app read.
  Stream<({int done, int total})> get storesProgress => _storesProgress.stream;

  final _acpInstallProgress = StreamController<AcpInstallProgress>.broadcast(
    sync: true,
  );

  /// Each step of an ACP agent install the server is doing, as told.
  Stream<AcpInstallProgress> get acpInstallProgress =>
      _acpInstallProgress.stream;

  /// The Flutter apps the server is attached to, as last told (slice 3d);
  /// null until the server has said.
  FlutterAppRegistry? flutterApps;

  /// The runs the server hosts for everybody to watch, by run id.
  final hostedRuns = <String, HostedRun>{};

  /// The server's browser, as last told; null until the server has said.
  BrowserState? browserState;

  /// Who drives which device on the server's machine, as last told (slice
  /// 4a).
  List<DeviceHold> deviceHolds = const [];

  final _runsChanges = StreamController<RunsChange>.broadcast(sync: true);

  /// The server's apps, runs and browser moving.
  Stream<RunsChange> get runsChanges => _runsChanges.stream;

  final _intents = StreamController<ClientIntent>.broadcast(sync: true);

  /// What the server asks this window to show (slice 5b) — told to this
  /// client alone, as the one a person last used.
  Stream<ClientIntent> get intents => _intents.stream;

  /// A live stream of the server's [source] (`kFlutterLogsStream`), on the
  /// link there is now; it ends with that link.
  Stream<DataStreamItems> openStream(String source, String key) {
    final endpoint = _endpoint;
    if (_closed || endpoint == null) return Stream.error(_notRunning());
    return endpoint.openStream(source, key);
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
  Future<void> resync(DataDomain domain) async => (await _read(domain, send))();

  /// Reads [domain] whole through [send]; the callback replaces its copy.
  Future<void Function()> _read(
    DataDomain domain,
    Future<DataReply<R>> Function<R>(DataRequest<R> request) send,
  ) => switch (domain) {
    DataDomain.notes => _then(send(const NotesList()), _replaceNotes),
    DataDomain.todos => _then(send(const TodosList()), _replaceTodos),
    DataDomain.preferences => _then(
      send(const PreferencesGet()),
      _replacePreferences,
    ),
    DataDomain.workspace => _then(
      send(const WorkspaceList()),
      _replaceWorkspace,
    ),
    DataDomain.sessions => _then(send(const SessionsList()), _replaceSessions),
    DataDomain.environments => _then(
      send(const EnvironmentsList()),
      _replaceEnvironments,
    ),
    DataDomain.agents => _then(send(const AgentsList()), _replaceAgents),
    DataDomain.automations => _then(
      send(const AutomationsList()),
      (reply) => automations.replace(reply.value, reply.revision),
    ),
    DataDomain.pairings => _then(
      send(const DevicesList()),
      (reply) => devices.replaceAll({
        for (final device in reply.value) device.id: device,
      }, reply.revision),
    ),
    DataDomain.worktrees => _then(send(const WorktreesList()), (reply) {
      final WorktreesSnapshot(:setups, :runs, :threads) = reply.value;
      worktreeSetups.replaceAll(setups, reply.revision);
      worktreeRuns.replaceAll({for (final r in runs) r.key: r}, reply.revision);
      reviewThreads.replaceAll({
        for (final t in threads) t.id: t,
      }, reply.revision);
    }),
    DataDomain.evidence =>
      Future.wait([
        _then(
          send(const VerificationRuns()),
          (reply) => verificationRuns.replaceAll({
            for (final run in reply.value) run.id: run,
          }, reply.revision),
        ),
        _then(
          send(const ComparisonsList()),
          (reply) => comparisons.replaceAll({
            for (final c in reply.value) c.id: c,
          }, reply.revision),
        ),
      ]).then(
        (replace) => () {
          for (final apply in replace) {
            apply();
          }
        },
      ),
    DataDomain.snippets => _then(send(const SnippetsList()), (reply) {
      snippets.replaceAll({
        for (final s in reply.value.snippets) s.id: s,
      }, reply.revision);
      presets.replaceAll({
        for (final p in reply.value.presets) p.id: p,
      }, reply.revision);
    }),
  };

  static Future<void Function()> _then<R>(
    Future<DataReply<R>> reply,
    void Function(DataReply<R> reply) replace,
  ) => reply.then(
    (reply) =>
        () => replace(reply),
  );

  /// The order a snapshot primes the copies in: the sessions last, so a
  /// reader primed by their rows finds what they name (the workspace, where
  /// agents run, the agents) in place.
  static final List<DataDomain> _primeOrder = [
    for (final domain in DataDomain.values)
      if (domain != DataDomain.sessions) domain,
    DataDomain.sessions,
  ];

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
    acpAgents.replaceAll({
      for (final r in snapshot.acpAgents) r.id: r,
    }, revision);
    usageStates.replaceAll({
      for (final u in snapshot.usage) u.accountKey: u,
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
      case UsageStateChanged(:final state):
        usageStates.applyAt(state.accountKey, state, revision);
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

  void _applyEvidence(EvidenceChange change, int revision) {
    switch (change) {
      case VerificationRunChanged(:final run):
        verificationRuns.applyAt(run.id, run, revision);
      case VerificationRunRemoved(:final id):
        verificationRuns.applyAt(id, null, revision);
      case ComparisonChanged(:final comparison):
        comparisons.applyAt(comparison.id, comparison, revision);
      case ComparisonRemoved(:final id):
        comparisons.applyAt(id, null, revision);
      case CheckpointRecorded() ||
          CheckpointsPruned() ||
          CheckpointSkipChanged() ||
          VerificationEvidenceAdded():
        break;
    }
    if (!_evidenceChanges.isClosed) _evidenceChanges.add(change);
  }

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
          if (row is RepositoryRemoved) {
            automations.checkoutRemoved(row.id, batch.revision);
          }
        case final AutomationsChange change:
          automations.apply(change, batch.revision);
        case final SessionDomainChange change:
          applySessionChange(change, batch.revision);
          if (change is SessionRowRemoved) {
            automations.sessionRemoved(change.id, batch.revision);
          }
        case DeviceChanged(:final device):
          devices.applyAt(device.id, device, batch.revision);
        case DeviceRemoved(:final id):
          devices.applyAt(id, null, batch.revision);
        case final HostsDomainChange change:
          applyHostsChange(change, batch.revision);
        case AcpAgentChanged(:final row):
          acpAgents.applyAt(row.id, row, batch.revision);
        case AcpAgentRemoved(:final id):
          acpAgents.applyAt(id, null, batch.revision);
        case WorktreeSetupChanged(:final repositoryId, :final setup):
          worktreeSetups.applyAt(repositoryId, setup, batch.revision);
        case WorktreeRunRecorded(:final report):
          worktreeRuns.applyAt(report.key, report, batch.revision);
        case ReviewThreadChanged(:final thread):
          reviewThreads.applyAt(thread.id, thread, batch.revision);
        case WorktreeRunRemoved(:final key):
          worktreeRuns.applyAt(key, null, batch.revision);
        case ReviewThreadRemoved(:final id):
          reviewThreads.applyAt(id, null, batch.revision);
        case SnippetChanged(:final snippet):
          snippets.applyAt(snippet.id, snippet, batch.revision);
        case SnippetRemoved(:final id):
          snippets.applyAt(id, null, batch.revision);
        case PresetChanged(:final preset):
          presets.applyAt(preset.id, preset, batch.revision);
        case PresetRemoved(:final id):
          presets.applyAt(id, null, batch.revision);
        case final EvidenceChange change:
          _applyEvidence(change, batch.revision);
        case final SshChange change:
          if (change case SshConnectionChanged(:final hostId, :final state)) {
            sshConnections[hostId] = state;
          }
          if (!_sshChanges.isClosed) _sshChanges.add(change);
        case final GitChange change:
          if (!_gitChanges.isClosed) _gitChanges.add(change);
        case final RunsChange change:
          switch (change) {
            case FlutterAppsChanged(:final registry):
              flutterApps = registry;
            case HostedRunChanged(:final run):
              hostedRuns[run.runId] = run;
            case HostedRunRemoved(:final runId):
              hostedRuns.remove(runId);
            case BrowserStateChanged(:final state):
              browserState = state;
            case DeviceClaimsChanged(:final holds):
              deviceHolds = holds;
          }
          if (!_runsChanges.isClosed) _runsChanges.add(change);
        case final FileChanged change:
          if (!_fileChanges.isClosed) _fileChanges.add(change);
        case final TranscriptChanged change:
          if (!_transcriptChanges.isClosed) _transcriptChanges.add(change);
        case final SessionModesChanged change:
          sessionModes[change.sessionId] = change;
          if (!_sessionModeChanges.isClosed) _sessionModeChanges.add(change);
        case final SessionConfigOptionsChanged change:
          sessionConfigOptions[change.sessionId] = change;
          if (!_sessionConfigOptionChanges.isClosed) {
            _sessionConfigOptionChanges.add(change);
          }
        case final SessionUsageChanged change:
          sessionUsage[change.sessionId] = change;
          if (!_sessionUsageChanges.isClosed) _sessionUsageChanges.add(change);
        case final TerminalChange change:
          switch (change) {
            case TerminalChanged(:final terminal):
              terminals[terminal.sessionId] = terminal;
            case TerminalRemoved(:final sessionId):
              terminals.remove(sessionId);
          }
          if (!_terminalChanges.isClosed) _terminalChanges.add(change);
        case EnvVariablesChanged(:final variables):
          envVariables = variables;
          if (!_envChanges.isClosed) _envChanges.add(variables);
        case QuickAccessChanged(:final pins):
          _setQuickAccess(pins);
        case StoresChanged(:final view):
          storesView = view;
          if (!_storesChanges.isClosed) _storesChanges.add(view);
        case StoresProgress(:final done, :final total):
          if (!_storesProgress.isClosed) {
            _storesProgress.add((done: done, total: total));
          }
        case final AcpInstallProgress progress:
          if (!_acpInstallProgress.isClosed) {
            _acpInstallProgress.add(progress);
          }
        case final AttentionChange change:
          _applyAttention(change);
        case final ClientIntent intent:
          if (!_intents.isClosed) _intents.add(intent);
      }
    }
  }

  void _applyAttention(AttentionChange change) {
    switch (change) {
      case SessionStatusChanged(:final entry):
        sessionStatuses[entry.openId] = entry;
      case SessionStatusRemoved(:final openId):
        sessionStatuses.remove(openId);
      case WatchCoverageChanged(:final coverage):
        watchCoverage = coverage;
      case InboxChanged(:final snapshot):
        attention = snapshot;
      case ForgeReadingChanged(:final checkout, :final reading):
        forgeReadings[checkout] = reading;
      case AttentionNewsTold() || InboxOpenWanted() || UsageLimitNoticed():
        break;
    }
    if (!_attentionChanges.isClosed) _attentionChanges.add(change);
  }

  /// A new link is greeted with every status the server keeps now: what
  /// this copy held from the last one is let go first, each told removed.
  void _forgetStatuses() {
    for (final openId in sessionStatuses.keys.toList()) {
      _applyAttention(SessionStatusRemoved(openId));
    }
    // Greeted again whole; a reading the new link does not repeat is gone.
    forgeReadings.clear();
    // Greeted only when something is pinned: silence means none.
    if (quickAccessPins.isNotEmpty) _setQuickAccess(const []);
  }

  Future<void> _attach(DataEndpoint endpoint) async {
    _forgetStatuses();
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
    final replace = await Future.wait([
      for (final domain in _primeOrder) _read(domain, endpoint.send),
    ]);
    for (final apply in replace) {
      apply();
    }
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
    // What the server's connections were doing is no longer known.
    sshConnections.clear();
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
    if (_redialing || _dial == null || _firstDialing) return;
    _redialing = true;
    try {
      for (var attempt = 0; !_closed && _endpoint == null; attempt++) {
        await _sleep(
          _redialHoldOff?.call() ??
              _backoff[math.min(attempt, _backoff.length - 1)],
        );
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
    unawaited(_evidenceChanges.close());
    unawaited(_sshChanges.close());
    unawaited(_envChanges.close());
    unawaited(_quickAccessChanges.close());
    unawaited(_storesChanges.close());
    unawaited(_storesProgress.close());
    unawaited(_acpInstallProgress.close());
    unawaited(_gitChanges.close());
    unawaited(_runsChanges.close());
    unawaited(_intents.close());
    unawaited(_fileChanges.close());
    unawaited(_transcriptChanges.close());
    unawaited(_sessionModeChanges.close());
    unawaited(_sessionConfigOptionChanges.close());
    unawaited(_sessionUsageChanges.close());
    unawaited(_terminalChanges.close());
    unawaited(_attentionChanges.close());
    unawaited(notes.dispose());
    unawaited(todos.dispose());
    unawaited(preferences.dispose());
    automations.dispose();
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
      usageStates,
      devices,
      worktreeSetups,
      worktreeRuns,
      reviewThreads,
      snippets,
      presets,
      verificationRuns,
      comparisons,
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
