import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show ImportedSession;
import 'package:agent_cli/usage.dart'
    show ClaudeAccount, CodexAccount, UsageSample;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_git/git.dart'
    show WorktreeSetup, WorktreeSetupReport;
import 'package:karmashala_core/util.dart' as core show Clock;
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;
import 'package:karmashala_store/database.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../domain/uuid.dart';
import '../sessions/session_input.dart';
import '../sessions/session_media.dart';
import '../sessions/session_subagents.dart';
import '../sessions/session_modes.dart';
import '../sessions/session_record_readings.dart';
import '../sessions/session_transcripts.dart';
import '../stores/store_desk.dart';
import 'agent_work.dart';
import 'attention_work.dart';
import 'acp_agents_handler.dart';
import 'automations_handler.dart';
import 'conversations_handler.dart';
import 'evidence_handler.dart';
import 'filing_lookup.dart';
import 'env_work.dart';
import 'files_work.dart';
import 'git_work.dart';
import 'hosts_handler.dart';
import 'notes_handler.dart';
import 'pairings_handler.dart';
import 'preferences_handler.dart';
import 'quick_access_handler.dart';
import 'snippets_handler.dart';
import 'ssh_work.dart';
import 'data_streams.dart';
import 'runs_work.dart';
import 'session_work.dart';
import 'sessions_handler.dart';
import 'terminal_work.dart';
import 'todos_handler.dart';
import 'workspace_handler.dart';
import 'worktrees_handler.dart';

/// The server's data API over its store: every client's reads and writes of
/// notes, todos, preferences, the workspace, sessions, and where agents run
/// and who they run as (environments, SSH hosts, trusted host keys, agent
/// installations, saved accounts, usage history), whatever link carries them. The only writer of those tables for a client; each write is
/// numbered ([revision]) and told to every other subscribed [DataSession] —
/// and so is each write the server makes itself ([announce]): a status it
/// recorded, a session a phone or an automation started.
class DataService {
  DataService(
    AppDatabase database, {
    DateTime Function()? clock,
    String Function()? newId,
    bool Function(String sessionId)? runsSession,
    bool Function(String path)? opens,
    AgentRegistry agents = AgentRegistry.builtIn,
  }) : _database = database,
       _now = clock ?? _utcNow {
    final filing = FilingLookup(database);
    _notes = NotesHandler(database, filing, _now);
    _todos = TodosHandler(database, filing, _now);
    _preferences = PreferencesHandler(database);
    _automations = AutomationsHandler(
      database,
      _now,
      written: () => automationsWritten?.call(),
    );
    _worktrees = WorktreesHandler(database, _now);
    _snippets = SnippetsHandler(database, _now);
    _quickAccess = QuickAccessHandler(database);
    _pairings = PairingsHandler(database);
    _sessions = SessionsHandler(database, _now, runs: runsSession);
    _hosts = HostsHandler(
      database,
      _now,
      opens: opens,
      agents: agents,
      newId: newId ?? newUuid,
    );
    _evidence = EvidenceHandler(database, _now);
    _acpAgents = AcpAgentsHandler(database, _now, newId ?? newUuid);
    conversations = ConversationsHandler(database, _Clock(_now));
    _workspace = WorkspaceHandler(
      database,
      _now,
      newId ?? newUuid,
      checkoutsGoing: (ids) {
        final sessions = _sessions.checkoutsGoing(ids);
        final comparisons = _evidence.checkoutsGoing(ids);
        final worktrees = _worktrees.checkoutsGoing(ids);
        return () => [...sessions(), ...comparisons(), ...worktrees()];
      },
      liveAcpSessions: () => liveAcpSessions(),
    );
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  final AppDatabase _database;
  final DateTime Function() _now;

  /// The server's agent components (usage, accounts, detection, the CLI
  /// import), set by `serve`; without them that work is refused
  /// `unavailable`.
  AgentWork? agentWork;

  /// The server's own SSH (a test connection, a disconnect, a prompt's
  /// answer), set by `serve`; without it that work is refused `unavailable`.
  SshWork? sshWork;

  /// The server's git work (reads and writes of a checkout, worktrees and
  /// their cleanup, GitHub), set by `serve`; without it that work is refused
  /// `unavailable`.
  GitWork? gitWork;

  /// The server's Flutter loop and its browser (slice 3d), set by `serve`;
  /// without them that work is refused `unavailable`.
  FlutterWork? flutterWork;
  BrowserWork? browserWork;

  /// The live streams a client can open (`DataStreamEnvelope`), by source.
  final streamSources = <String, DataStreamSource>{};

  /// The server's files (a machine's listings, reads and writes, Quick
  /// Open's index, watches), set by `serve`; without it that work is refused
  /// `unavailable`.
  FilesWork? filesWork;

  /// The server's environment vault (slice 5a, write-only), set by `serve`;
  /// without it that work is refused `unavailable`.
  EnvVault? envVault;

  /// The app stores this server reads, set by `serve`; without it that work
  /// is refused `unavailable`.
  StoreWork? storeWork;

  /// The server's terminals (slice 5a: every local and WSL pane's PTY), set
  /// by `serve`; without them that work is refused `unavailable`.
  TerminalWork? terminalWork;

  /// The server's session status and attention inbox (slice 5c), set by
  /// `serve`; without them that work is refused `unavailable`.
  AttentionWork? attentionWork;

  /// A session's project checks run for a client (`checks.run`, slice 5c),
  /// set by `serve` once automations run; else refused `unavailable`.
  ChecksWork? checksWork;

  /// The server's one launch path (slice 5b: a start, a resume, a handoff, a
  /// fork, an end), set by `serve`; without it that work is refused
  /// `unavailable`.
  SessionWork? sessionWork;

  /// Sessions' transcripts read here for any client (`sessions.transcript`),
  /// set by `serve`; without them that work is refused `unavailable`.
  SessionTranscripts? sessionTranscripts;

  /// Rewind points, changed files and the open question, read off the same
  /// records (Stage 0 step 7); refused `unavailable` without them.
  SessionRecordReadings? sessionRecordReadings;

  /// Sessions' pictures, extracted here (Stage 0 step 10); refused
  /// `unavailable` without it.
  SessionMedia? sessionMedia;

  /// A session's subagents and child sessions; refused `unavailable` without
  /// it.
  SessionSubagents? sessionSubagents;

  /// A client's chat sends and Stop, typed as host keys (Stage 2 step 2);
  /// refused `unavailable` without it.
  SessionInput? sessionInput;

  /// Where `sessions.setMode` lands (ACP design, C5): the ACP runtime replaces
  /// the default, which refuses every session as having no modes.
  SessionModeChanger sessionModes = const NoSessionModes();

  /// The session ids an ACP runtime of this server runs right now; set by
  /// `serve`. A project holding one is not deleted.
  Set<String> Function() liveAcpSessions = _noLiveAcpSessions;

  static Set<String> _noLiveAcpSessions() => const {};
  late final NotesHandler _notes;
  late final TodosHandler _todos;
  late final PreferencesHandler _preferences;
  late final AutomationsHandler _automations;

  /// Told after a client wrote automations, runs, checks or resumes: the
  /// server's scheduler re-arms and drains what it can start.
  void Function()? automationsWritten;

  /// Does the checkpoint work a client asks for ([CheckpointWorkRequest]:
  /// capture, a run's base, diff, restore, skip reasons) — the server's
  /// checkpoint recorder. Null refuses it (`unavailable`).
  Future<Object?> Function(CheckpointWorkRequest<Object?> request)?
  checkpointWork;
  late final WorktreesHandler _worktrees;
  late final SnippetsHandler _snippets;
  late final QuickAccessHandler _quickAccess;
  late final PairingsHandler _pairings;
  late final WorkspaceHandler _workspace;
  late final SessionsHandler _sessions;
  late final HostsHandler _hosts;
  late final EvidenceHandler _evidence;
  late final AcpAgentsHandler _acpAgents;

  /// The conversation index: searched by every client, kept once [serve]
  /// starts it with the agents' stores.
  late final ConversationsHandler conversations;
  final _links = <DataSession>{};
  var _revision = 0;
  final _changeListeners = <void Function(List<DataChange> changes)>[];

  /// Tells [listener] of every write, a client's or the server's own — how
  /// the server's own components follow the rows (usage asks again when a
  /// session moves).
  void addChangeListener(void Function(List<DataChange> changes) listener) =>
      _changeListeners.add(listener);

  void removeChangeListener(void Function(List<DataChange> changes) listener) =>
      _changeListeners.remove(listener);

  void _noticed(List<DataChange> changes) {
    conversations.noticed(changes);
    for (final listener in [..._changeListeners]) {
      listener(changes);
    }
  }

  /// The number of the last write, since this service started.
  int get revision => _revision;

  /// Whether a client is subscribed to be told things — a desktop app; the
  /// server's own links and a phone's companion never subscribe. What the
  /// server's SSH asks a person goes only where somebody can answer.
  bool get hasSubscribers => _links.any((link) => link._subscribed);

  /// Whether a subscribed client may be asked the server's SSH questions — a
  /// window on this machine, or a paired one granted them (slice 5e).
  bool get hasPromptAnswerers =>
      _links.any((link) => link._subscribed && link.sshPrompts);

  /// How many clients are subscribed now — the windows a cue to show
  /// something (`inbox.open`) reaches.
  int get subscriberCount => _links.where((link) => link._subscribed).length;

  /// Numbers each subscription and each [ClientActive], so "the client a
  /// person last used" is an order, not a clock.
  var _lastSignOfLife = 0;

  /// The desktop client a window's intent goes to: the one whose last sign of
  /// life — subscribing, or a person acting in it ([ClientActive]) — is the
  /// newest. A link that died without closing is passed over as soon as
  /// another client connects. Null with no desktop client connected.
  DataSession? get intentTarget {
    DataSession? best;
    for (final link in _links) {
      if (!link._subscribed) continue;
      if (best == null || link._signOfLife > best._signOfLife) best = link;
    }
    return best;
  }

  /// Tells [intent] to [intentTarget] alone. False when no desktop client is
  /// connected — the caller says so in words, never waits for one.
  bool tellIntent(ClientIntent intent) {
    final target = intentTarget;
    if (target == null) return false;
    target.tell([intent]);
    return true;
  }

  /// The pane in front of a person in [intentTarget]'s window, as it last
  /// said; null when it never said, or no desktop client is connected.
  String? get focusedPaneId => intentTarget?._focusedPaneId;

  /// One client link. [deliver] gets the changes other links make once the
  /// client has sent [DataSubscribe].
  ///
  /// A link from another machine passes what its pairing grants: without
  /// [admin] it may not rename, grant or revoke devices; without
  /// [sshPrompts] it is neither told nor may answer an SSH question; without
  /// [transcripts] it may not read a session's transcript. A [phone] is also
  /// refused what [phoneRefusal] names, by its [grants].
  DataSession open(
    void Function(DataChanges changes) deliver, {
    bool admin = true,
    bool sshPrompts = true,
    bool transcripts = true,
    bool phone = false,
    CapabilitySet? grants,
    String? device,
  }) {
    final link = DataSession._(
      this,
      sshPrompts ? deliver : (batch) => deliver(_withoutPrompts(batch)),
      admin: admin,
      sshPrompts: sshPrompts,
      transcripts: transcripts,
      phone: phone,
      grants: grants,
      device: device,
    );
    _links.add(link);
    return link;
  }

  /// Tells every subscribed client of [changes] the server made itself,
  /// outside any request, under the next revision.
  void announce(List<DataChange> changes) {
    if (changes.isEmpty) return;
    _noticed(changes);
    _tell(null, DataChanges(++_revision, List.unmodifiable(changes)));
  }

  /// [announce]s sessions [sessionIds] as they now stand — rows the server
  /// wrote itself: a lifecycle status, a session it started, a mode a phone
  /// chose. A row that is gone is told removed.
  void announceSessions(Iterable<String> sessionIds) =>
      announce(_sessions.sessionsNow(sessionIds));

  /// Records the agent CLIs the server found on this machine ([here]) by
  /// the one reconciliation rule, and tells every client what it wrote.
  /// [forgotten] names the agent kinds the registry no longer knows, whose
  /// leftover rows go.
  InstallationsReconciled recordAgentsFound(
    ExecutionEnvironment here,
    List<AgentInstallation> found,
    DateTime readAt, {
    Set<String> forgotten = const {},
  }) {
    final changes = <DataChange>[];
    final result = _hosts.recordFound(
      here,
      found,
      readAt,
      changes,
      forgotten: forgotten,
    );
    announce(changes);
    return result;
  }

  /// Records [environment] unless it is there — this machine's, at start —
  /// and tells every client when it was new.
  void ensureEnvironment(ExecutionEnvironment environment) {
    final changes = <DataChange>[];
    _hosts.ensureEnvironment(environment, changes);
    announce(changes);
  }

  /// Tells every client the paired devices as they now stand, without
  /// secrets — after the companion wrote them itself.
  void announceDevices() => announce(_pairings.devicesNow());

  /// Set by the companion: brings the phones' live links in line after a
  /// client renamed, granted or revoked a device.
  set onDevicesWritten(void Function()? apply) => _pairings.onWritten = apply;

  /// Records how a worktree the server made was set up, and tells every
  /// client.
  void recordWorktreeSetup(WorktreeSetupReport report) {
    final changes = <DataChange>[];
    _worktrees.record(report, changes);
    announce(changes);
  }

  /// What checkout [repositoryId] asks of a new worktree.
  WorktreeSetup worktreeSetupOf(String repositoryId) =>
      _worktrees.setupOf(repositoryId);

  /// The ACP agents a person added, oldest first — what the server's agent
  /// registry is composed from (`AgentRegistryHolder`).
  List<AcpAgentRow> get acpAgents => _acpAgents.list();

  /// The installations recorded in [environmentId], oldest first.
  List<AgentInstallation> installationsIn(String environmentId) =>
      _hosts.installationsIn(environmentId);

  // What the server's agent components read and write — as the server, told
  // to every client.

  /// Every recorded installation, oldest first.
  List<AgentInstallation> get installations => _hosts.allInstallations();

  /// Every recorded environment.
  List<ExecutionEnvironment> get environments => _hosts.allEnvironments();

  /// Every imported conversation, for the server's own upkeep (the import's
  /// prune): not a client request.
  List<ImportedSession> get importedSessions => _sessions.allImported();

  /// Where every project and checkout the workspace names lives — what a
  /// file browser's delete must never take.
  List<EnvironmentPath> get workspaceRoots {
    final workspace = _workspace.list();
    return [
      for (final project in workspace.projects) project.root,
      for (final repository in workspace.repositories) repository.path,
    ];
  }

  /// Records a probe of [environmentId] by the one rule (`planReconcile`).
  InstallationsReconciled reconcileProbe({
    required String environmentId,
    required DateTime readAt,
    required List<AgentInstallation> found,
    required Set<String> probed,
    required Map<String, ExecutableReachability> readings,
  }) => _asServer(
    'recording what was found',
    (changes) => _hosts.reconcile(
      environmentId: environmentId,
      readAt: readAt,
      found: found,
      probed: probed,
      readings: readings,
      changes: changes,
    ),
  );

  /// Records what installation [id]'s CLI answered.
  void recordInstallationVersion(String id, String version, DateTime readAt) =>
      _asServer(
        'recording a version',
        (changes) => _hosts.recordVersion(id, version, readAt, changes),
      );

  /// Saves a captured Claude account; answers it without credentials.
  ClaudeAccount saveClaudeAccount(ClaudeAccount account) =>
      _asServer('saving an account', (changes) {
        return _hosts.saveClaudeAccount(account, changes);
      });

  /// Saves a captured Codex account; answers it without credentials.
  CodexAccount saveCodexAccount(CodexAccount account) =>
      _asServer('saving an account', (changes) {
        return _hosts.saveCodexAccount(account, changes);
      });

  /// [write] as the server, told to every client — and, failing, refused in
  /// the store's own words, never a statement's values (a saved account's
  /// credentials are some).
  T _asServer<T>(String what, T Function(List<DataChange> changes) write) {
    final changes = <DataChange>[];
    final T result;
    try {
      result = write(changes);
    } on DataRefused {
      rethrow;
    } on Object catch (error) {
      throw DataRefused(
        DataRefusalCode.failed,
        '$what failed: ${error is SqliteException ? error.message : error}',
      );
    }
    announce(changes);
    return result;
  }

  /// Saved account [id] **with** its credentials — never answered to a
  /// client; the server reads it to switch an installation.
  ClaudeAccount claudeAccount(String id) => _hosts.claudeAccount(id);
  CodexAccount codexAccount(String id) => _hosts.codexAccount(id);

  /// Records one reading's samples in the usage history; answers how many
  /// rows it kept.
  int recordUsage(List<UsageSample> samples) => samples.isEmpty
      ? 0
      : _asServer(
          'recording usage',
          (changes) => _hosts.recordUsage(samples, changes),
        );

  /// Tells every client an account's usage as it now stands.
  void announceUsage(AccountUsageState state) =>
      announce([UsageStateChanged(state)]);

  /// A server-owned `app_metadata` value (a reserved key).
  String? serverValue(String key) => _database.readMetadata(key);

  void setServerValue(String key, String value) =>
      _database.writeMetadata(key, value);

  /// [request] applied as the server itself — validated and written by the
  /// same handler a client's is, and told to every client.
  R applyAsServer<R>(DataRequest<R> request) => _handle(null, request).value;

  /// Told every batch the server tells, whoever wrote it — the server's own
  /// parts that follow rows (the device claims release an ended session's
  /// devices). Not a link: nothing here counts as a subscribed client.
  final watchers = <void Function(List<DataChange> changes)>[];

  /// What each of the server's own parts tells a client that subscribes, on
  /// arrival (the device claims standing now).
  final greeters = <List<DataChange> Function()>[];

  void _tell(DataSession? origin, DataChanges batch) {
    for (final watcher in List.of(watchers)) {
      watcher(batch.changes);
    }
    for (final link in _links) {
      if (link != origin && link._subscribed) link._deliver(batch);
    }
  }

  static DataChanges _withoutPrompts(DataChanges batch) => DataChanges(
    batch.revision,
    List.unmodifiable([
      for (final change in batch.changes)
        if (change is! SshPromptOpened) change,
    ]),
  );

  DataReply<R> _handle<R>(DataSession? origin, DataRequest<R> request) {
    if (origin != null &&
        !origin.admin &&
        (request is DeviceRename ||
            request is DeviceGrant ||
            request is DeviceRevoke)) {
      throw const DataRefused.denied(
        'this client may not change paired devices: its pairing does not '
        'grant administering this server',
      );
    }
    final changes = <DataChange>[];
    final Object? result;
    try {
      result = switch (request) {
        DataSubscribe() =>
          origin?._subscribe() ??
              (throw const DataRefused.invalid(
                'the server subscribes to nothing',
              )),
        // Reads disks and endpoints, so answered when done:
        // `DataSession.handleLater`.
        AgentWorkRequest() ||
        SshWorkRequest() ||
        GitWorkRequest() ||
        FlutterWorkRequest() ||
        BrowserWorkRequest() ||
        FilesWorkRequest() ||
        TerminalWorkRequest() ||
        ChecksWorkRequest() ||
        SessionWorkRequest() ||
        SessionTranscriptRequest() ||
        SessionInputRequest() ||
        SessionSetMode() ||
        SessionSetConfigOption() ||
        EnvVaultRequest() ||
        StoreRequest() => throw DataRefused.invalid(
          '${request.kind} is answered asynchronously',
        ),
        final AttentionRequest r =>
          (attentionWork ??
                  (throw const DataRefused.unavailable(
                    'this server keeps no session status',
                  )))
              .handle(r, origin),
        final ClientActive r =>
          origin?._active(r.focusedPaneId) ??
              (throw const DataRefused.invalid('the server has no window')),
        final AutomationsRequest r => _automations.handle(r, changes),
        final CheckpointsRequest r => _evidence.handleCheckpoints(r, changes),
        // Runs git, so answered when done: `DataSession.handleLater`.
        CheckpointWorkRequest() => throw DataRefused.invalid(
          '${request.kind} is answered asynchronously',
        ),
        final VerificationRequest r => _evidence.handleVerification(r, changes),
        final ComparisonsRequest r => _evidence.handleComparisons(r, changes),
        final WorktreesRequest r => switch (r) {
          WorktreesList() => _worktrees.list(),
          final WorktreeSetupSave r => _worktrees.save(r, changes),
          final WorktreeSetupClear r => _worktrees.clear(r, changes),
          final WorktreeSetupRecord r => _worktrees.record(r.report, changes),
          final ReviewThreadOpen r => _worktrees.open(r, changes),
          final ReviewThreadReply r => _worktrees.reply(r, changes),
          final ReviewThreadSetStatus r => _worktrees.setStatus(r, changes),
        },
        final QuickAccessRequest r => _quickAccess.handle(r, changes),
        final AcpAgentsRequest r => switch (r) {
          AcpAgentsList() => _acpAgents.list(),
          final AcpAgentPut r => _acpAgents.put(r, changes),
          final AcpAgentDelete r => _acpAgents.delete(r, changes),
        },
        final SnippetsRequest r => switch (r) {
          SnippetsList() => _snippets.list(),
          final SnippetAdd r => _snippets.add(r, changes),
          final SnippetEdit r => _snippets.edit(r, changes),
          final SnippetDelete r => _snippets.delete(r, changes),
          final PresetSave r => _snippets.savePreset(r, changes),
          final PresetDelete r => _snippets.deletePreset(r, changes),
        },
        final ConversationsRequest r => switch (r) {
          final ConversationsSearch r => conversations.searchFor(r),
          final ConversationsTurns r => conversations.turns(r),
          ConversationsStatus() => conversations.status(),
          // Reads transcripts, so answered when done: `DataSession.handleLater`.
          ConversationsCatchUp() => throw const DataRefused.invalid(
            'conversations.catchUp is answered asynchronously',
          ),
        },
        final PairingsRequest r => switch (r) {
          DevicesList() => _pairings.list(),
          final DeviceRename r => _pairings.rename(r, changes),
          final DeviceGrant r => _pairings.grant(r, changes),
          final DeviceRevoke r => _pairings.revoke(r, changes),
        },
        final NotesList r => _notes.list(r),
        final NoteCapture r => _notes.capture(r, changes),
        final NoteEdit r => _notes.edit(r, changes),
        final NoteFile r => _notes.file(r, changes),
        final NoteDelete r => _notes.delete(r, changes),
        TodosList() => _todos.list(),
        final TodoAdd r => _todos.add(r, changes),
        final TodoSetDone r => _todos.setDone(r, changes),
        final TodoEdit r => _todos.edit(r, changes),
        final TodoFile r => _todos.file(r, changes),
        final TodoMove r => _todos.move(r, changes),
        final TodoDelete r => _todos.delete(r, changes),
        final TodosClearDone r => _todos.clearDone(r, changes),
        PreferencesGet() => _preferences.all(),
        final PreferenceSet r => _preferences.set(r, changes),
        final PreferenceRemove r => _preferences.remove(r, changes),
        WorkspaceList() => _workspace.list(),
        final WorkspacePut r => _workspace.putWorkspace(r, changes),
        final WorkspaceSetColor r => _workspace.setColor(r, changes),
        final WorkspaceDelete r => _workspace.deleteWorkspace(r, changes),
        final ProjectCreate r => _workspace.createProject(r, changes),
        final ProjectUpdate r => _workspace.updateProject(r, changes),
        final ProjectsFile r => _workspace.fileProjects(r, changes),
        final ProjectDelete r => _workspace.deleteProject(r, changes),
        final ProjectsUsingEnvironment r => _workspace.projectsUsing(r),
        final CheckoutsAdd r => _workspace.addCheckouts(r, changes),
        final CheckoutsRetire r => _workspace.retireCheckouts(r, changes),
        final CheckoutsIdentify r => _workspace.identifyCheckouts(r, changes),
        final SectionPut r => _workspace.putSection(r, changes),
        final SectionsReorder r => _workspace.reorderSections(r, changes),
        final SectionDelete r => _workspace.deleteSection(r, changes),
        SessionsList() => _sessions.list(),
        final SessionCreate r => _sessions.create(r, changes),
        final SessionEdit r => _sessions.edit(r, changes),
        final SessionDelete r => _sessions.delete(r, changes),
        final SessionLinkAdd r => _sessions.link(r, changes),
        final SessionLinkRemove r => _sessions.unlink(r, changes),
        final SessionEvents r => _sessions.events(r),
        final SessionEventsLatest r => _sessions.lastEventAt(r),
        final SessionEventsAppend r => _sessions.appendEvents(r),
        final DecisionAppend r => _sessions.recordDecision(r, changes),
        final RecapWrite r => _sessions.writeRecap(r, changes),
        final RecapDismiss r => _sessions.dismissRecap(r, changes),
        final RelayRecord r => _sessions.recordRelay(r),
        final RelaysTo r => _sessions.relaysTo(r),
        final RelayCount r => _sessions.relayCount(r),
        final FollowUpRaise r => _sessions.raiseFollowUp(r, changes),
        final FollowUpResolve r => _sessions.resolveFollowUp(r, changes),
        final ImportedAdd r => _sessions.addImported(r, changes),
        final ImportedRename r => _sessions.renameImported(r, changes),
        final ImportedDelete r => _sessions.deleteImported(r, changes),
        EnvironmentsList() => _hosts.environments(),
        final EnvironmentPut r => _hosts.putEnvironment(r, changes),
        final SshHostPut r => _hosts.putSshHost(r, changes),
        final SshHostDelete r => _hosts.deleteSshHost(r, changes),
        final KnownHostTrust r => _hosts.trustKey(r, changes),
        final KnownHostForget r => _hosts.forgetKey(r, changes),
        AgentsList() => _hosts.agents(
          usage: agentWork?.usageStates() ?? const [],
          acpAgents: _acpAgents.list(),
        ),
        final InstallationSetPath r => _hosts.setPath(r, changes),
        final ClaudeAccountDelete r => _hosts.deleteClaudeAccount(r, changes),
        final CodexAccountDelete r => _hosts.deleteCodexAccount(r, changes),
        final UsageHistory r => _hosts.usageHistory(r),
      };
    } on DataRefused {
      rethrow;
    } on Object catch (error) {
      // A store error in its own words, without the statement's values: a
      // save carries credentials, and SQLite's full text lists them.
      throw DataRefused(
        DataRefusalCode.failed,
        '${request.kind} failed: '
        '${error is SqliteException ? error.message : error}',
      );
    }
    if (changes.isEmpty) return DataReply(result as R, _revision);
    _noticed(changes);
    final batch = DataChanges(++_revision, List.unmodifiable(changes));
    _tell(origin, batch);
    return DataReply(result as R, _revision, batch.changes);
  }
}

/// One client's link to the [DataService].
class DataSession implements FileWatchLink, TranscriptWatchLink {
  DataSession._(
    this._service,
    this._deliver, {
    required this.admin,
    required this.sshPrompts,
    required this.transcripts,
    required this.phone,
    this.grants,
    this.device,
  });

  final DataService _service;

  /// The paired device's id, which outlives this link; null on this machine.
  final String? device;

  /// What this link's pairing grants (slice 5e); all true on this machine.
  final bool admin;
  final bool sshPrompts;
  final bool transcripts;

  /// The app on a phone (Stage 1): refused what [phoneRefusal] names.
  final bool phone;

  /// A [phone]'s pairing grants; null grants it every bit.
  final CapabilitySet? grants;

  void _refuseForPhone(DataRequest<Object?> request) {
    if (!phone) return;
    final refusal = phoneRefusal(request, grants: grants);
    if (refusal != null) throw DataRefused.denied(refusal);
  }

  final void Function(DataChanges changes) _deliver;
  var _subscribed = false;
  var _signOfLife = 0;
  String? _focusedPaneId;

  DataAck _active(String? focusedPaneId) {
    _signOfLife = ++_service._lastSignOfLife;
    _focusedPaneId = focusedPaneId;
    return const DataAck();
  }

  /// Answers [request] now, or throws [DataRefused]. A request that reads
  /// the disk ([isAnsweredLater]) is refused here: [handleLater] it.
  DataReply<R> handle<R>(DataRequest<R> request) {
    _refuseForPhone(request);
    return _service._handle(this, request);
  }

  /// Whether [request] is answered when its work is done rather than at
  /// once — out of order, which only a request that writes nothing a client
  /// copies may be.
  static bool isAnsweredLater(DataRequest<Object?> request) =>
      request is ConversationsCatchUp ||
      request is CheckpointWorkRequest ||
      request is AgentWorkRequest ||
      request is SshWorkRequest ||
      request is GitWorkRequest ||
      request is FlutterWorkRequest ||
      request is BrowserWorkRequest ||
      request is FilesWorkRequest ||
      request is TerminalWorkRequest ||
      request is ChecksWorkRequest ||
      request is SessionWorkRequest ||
      request is SessionTranscriptRequest ||
      request is SessionInputRequest ||
      request is SessionSetMode ||
      request is SessionSetConfigOption ||
      request is EnvVaultRequest ||
      request is StoreRequest;

  /// Answers any request: at once, or when its work is done. What agent work
  /// writes is told to every client, this one too, as it is written.
  Future<DataReply<R>> handleLater<R>(DataRequest<R> request) async {
    _refuseForPhone(request);
    if (request is ConversationsCatchUp) {
      final changed = await _service.conversations.catchUp();
      return DataReply(changed as R, _service._revision);
    }
    if (request is CheckpointWorkRequest) {
      // What it wrote was told as it wrote it (`announce`), to this link too.
      final work = _service.checkpointWork;
      if (work == null) {
        throw const DataRefused.unavailable('this server keeps no checkpoints');
      }
      final value = await work(request as CheckpointWorkRequest<Object?>);
      return DataReply(value as R, _service._revision);
    }
    if (request case final AgentWorkRequest<Object?> asked) {
      final work =
          _service.agentWork ??
          (throw const DataRefused.unavailable(
            'this server does no work for its agents',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final SshWorkRequest<Object?> asked) {
      if (asked is SshAnswerPrompt && !sshPrompts) {
        throw const DataRefused.denied(
          'this client may not answer SSH questions: its pairing does not '
          'grant it',
        );
      }
      final work =
          _service.sshWork ??
          (throw const DataRefused.unavailable('this server reaches no SSH'));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final GitWorkRequest<Object?> asked) {
      final work =
          _service.gitWork ??
          (throw const DataRefused.unavailable('this server does no git work'));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final FlutterWorkRequest<Object?> asked) {
      final work =
          _service.flutterWork ??
          (throw const DataRefused.unavailable(
            'this server runs no Flutter apps',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final BrowserWorkRequest<Object?> asked) {
      final work =
          _service.browserWork ??
          (throw const DataRefused.unavailable(
            'this server drives no browser',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final TerminalWorkRequest<Object?> asked) {
      final work =
          _service.terminalWork ??
          (throw const DataRefused.unavailable(
            'this server runs no terminals',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final SessionWorkRequest<Object?> asked) {
      final work =
          _service.sessionWork ??
          (throw const DataRefused.unavailable(
            'this server starts no sessions',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case SessionSetMode(:final sessionId, :final modeId)) {
      await _service.sessionModes.setMode(sessionId, modeId);
      return DataReply(const DataAck() as R, _service._revision);
    }
    if (request case SessionSetConfigOption(
      :final sessionId,
      :final configId,
      :final value,
    )) {
      await _service.sessionModes.setConfigOption(sessionId, configId, value);
      return DataReply(const DataAck() as R, _service._revision);
    }
    if (request case final SessionTranscriptRequest<Object?> asked) {
      if (!transcripts) {
        throw const DataRefused.denied(
          'this client may not read transcripts: its pairing does not grant it',
        );
      }
      SessionTranscripts work() =>
          _service.sessionTranscripts ??
          (throw const DataRefused.unavailable(
            'this server reads no transcripts',
          ));
      SessionRecordReadings readings() =>
          _service.sessionRecordReadings ??
          (throw const DataRefused.unavailable(
            'this server reads no session records',
          ));
      final Object? result = switch (asked) {
        final SessionTranscriptRead read => await work().page(read),
        final SessionTranscriptSubagent read => await work().subagent(read),
        final SessionTranscriptTurns read => await work().turns(read),
        SessionTranscriptWatch(:final sessionId) =>
          await work().watch(this, sessionId).then((_) => const DataAck()),
        SessionTranscriptUnwatch(:final sessionId) => () {
          work().unwatch(this, sessionId);
          return const DataAck();
        }(),
        SessionRewindPointsRead(:final sessionId) =>
          await readings().rewindPoints(sessionId),
        SessionChangedFilesRead(:final sessionId) =>
          await readings().changedFiles(sessionId),
        SessionOpenQuestionRead(:final sessionId) =>
          await readings().openQuestion(sessionId),
        final SessionStatsRead read => await readings().stats(read),
        final SessionMediaRead read =>
          await (_service.sessionMedia ??
                  (throw const DataRefused.unavailable(
                    'this server extracts no session media',
                  )))
              .list(read),
        final SessionSubagentsRead read =>
          await (_service.sessionSubagents ??
                  (throw const DataRefused.unavailable(
                    'this server lists no subagents',
                  )))
              .read(read),
      };
      return DataReply(result as R, _service._revision);
    }
    if (request case final SessionInputRequest<Object?> asked) {
      final work =
          _service.sessionInput ??
          (throw const DataRefused.unavailable(
            'this server types into no sessions',
          ));
      final result = await work.handle(asked, device);
      return DataReply(result as R, _service._revision);
    }
    if (request case final EnvVaultRequest<Object?> asked) {
      final work =
          _service.envVault ??
          (throw const DataRefused.unavailable(
            'this server keeps no environment variables',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final StoreRequest<Object?> asked) {
      final work =
          _service.storeWork ??
          (throw const DataRefused.unavailable(
            'this server holds no app stores',
          ));
      final result = await work.handle(asked);
      return DataReply(result as R, _service._revision);
    }
    if (request case final FilesWorkRequest<Object?> asked) {
      final work =
          _service.filesWork ??
          (throw const DataRefused.unavailable('this server reads no files'));
      final result = await work.handle(asked, this);
      return DataReply(result as R, _service._revision);
    }
    if (request case final ChecksRun asked) {
      final work =
          _service.checksWork ??
          (throw const DataRefused.unavailable(
            'this server runs no project checks',
          ));
      final result = await work.run(asked);
      return DataReply(result as R, _service._revision);
    }
    return handle(request);
  }

  /// Answers the envelope [json] with the envelope to send back — now, or
  /// (for [isAnsweredLater]) a future of it.
  FutureOr<Map<String, Object?>> handleJson(Map<String, Object?> json) {
    final read = DataEnvelope.readRequest(json);
    final request = read.request;
    if (request == null) return DataEnvelope.refusal(read.id, read.refusal!);
    if (isAnsweredLater(request)) return _answerLater(read.id, request);
    try {
      return _answer(read.id, request);
    } on DataRefused catch (refusal) {
      return DataEnvelope.refusal(read.id, refusal);
    }
  }

  Map<String, Object?> _answer<R>(int id, DataRequest<R> request) {
    return DataEnvelope.answer(id, request, handle(request));
  }

  Future<Map<String, Object?>> _answerLater<R>(
    int id,
    DataRequest<R> request,
  ) async {
    try {
      return DataEnvelope.answer(id, request, await handleLater(request));
    } on DataRefused catch (refusal) {
      return DataEnvelope.refusal(id, refusal);
    } on Object catch (error) {
      return DataEnvelope.refusal(
        id,
        DataRefused(DataRefusalCode.failed, '${request.kind} failed: $error'),
      );
    }
  }

  void close() {
    _service._links.remove(this);
    _service.filesWork?.linkClosed(this);
    _service.sessionTranscripts?.closed(this);
    _service.attentionWork?.linkClosed(this);
  }

  /// A change for this link alone — a path it watches moved — at the
  /// revision it already has: nothing of it is a row a copy keeps.
  @override
  void tell(List<DataChange> changes) {
    if (changes.isEmpty || !_service._links.contains(this)) return;
    _deliver(DataChanges(_service._revision, List.unmodifiable(changes)));
  }

  DataAck _subscribe() {
    _subscribed = true;
    _signOfLife = ++_service._lastSignOfLife;
    // What is already under way — a connection's state, a question still
    // open — told to this client alone, at the revision it is joining at.
    final greeting = [
      ...?_service.sshWork?.greeting(),
      ...?_service.flutterWork?.greeting(),
      ...?_service.browserWork?.greeting(),
      ...?_service.terminalWork?.greeting(),
      ...?_service.attentionWork?.greeting(),
      ..._service._quickAccess.greeting(),
      for (final greeter in _service.greeters) ...greeter(),
    ];
    if (greeting.isNotEmpty) {
      _deliver(DataChanges(_service._revision, List.unmodifiable(greeting)));
    }
    return const DataAck();
  }
}

/// Why the app on a phone may not ask [request], or null when it may. The
/// phone tier is a desktop client's minus what rewrites how this server is
/// secured: the env vault's writes, SSH hosts and known hosts, and agent
/// account deletes. Everything else is allowed on purpose — sessions,
/// transcripts, terminals, files (uploads, write, delete, move, mkdir),
/// projects, notes, todos, snippets, preferences, quick-access pins, git,
/// checks, Flutter and the browser. Admin and SSH prompts are refused by `LinkTrust`, not here.
///
/// Then by the pairing's [grants] (Stage 3 step 3), in the companion's words:
/// `send_prompt` — [SessionSend], [SessionInterrupt], [SessionQueueEdit],
/// [SessionQueueCancel], [SessionQueueSendNext]; `start_session` —
/// [SessionStart], [SessionResume], [SessionFork], [SessionForkFromCheckpoint],
/// [SessionHandoff], [SessionSwitchAgent]; `send_attachment` — [FilesUploadBegin]; `add_project` —
/// [ProjectCreate], [ProjectFoldersCreate], [ImportsAdd]; `view_usage` —
/// [UsageCurrent], [UsageRefresh], [UsageHistory]. `approve` is the host
/// protocol's prompt answer, and `read_transcript` is `LinkTrust.transcripts`.
/// The terminal is never refused: the bits guard against a slip, not a thief.
String? phoneRefusal(DataRequest<Object?> request, {CapabilitySet? grants}) {
  final denied = switch (request) {
    EnvSet() || EnvRemove() || EnvRename() =>
      'a phone may not change this server\'s environment variables or '
          'secrets; use a desktop paired with it',
    StoreAppleSet() || StorePlaySet() || StoreCredentialRemove() =>
      'a phone may not change the app-store credentials this server holds; '
          'import them on a desktop paired with it',
    SshHostPut() || SshHostDelete() || KnownHostTrust() || KnownHostForget() =>
      'a phone may not change this server\'s SSH hosts or trusted host keys; '
          'use a desktop paired with it',
    ClaudeAccountDelete() || CodexAccountDelete() =>
      'a phone may not delete this server\'s agent accounts; use a desktop '
          'paired with it',
    _ => null,
  };
  if (denied != null || grants == null) return denied;
  final needed = switch (request) {
    SessionSend() ||
    SessionInterrupt() ||
    SessionQueueEdit() ||
    SessionQueueCancel() ||
    SessionQueueSendNext() ||
    SessionSetMode() ||
    SessionSetConfigOption() => Capability.sendPrompt,
    // Letting an agent operate Karmashala lets it start and send to
    // sessions: no more than the phone may do itself.
    SessionEdit(:final patch) when patch.touchesOperatorGrant =>
      Capability.startSession,
    SessionStart() ||
    SessionResume() ||
    SessionFork() ||
    SessionForkFromCheckpoint() ||
    SessionHandoff() ||
    SessionSwitchAgent() => Capability.startSession,
    FilesUploadBegin() => Capability.sendAttachment,
    ProjectCreate() ||
    ProjectFoldersCreate() ||
    ImportsAdd() => Capability.addProject,
    UsageCurrent() || UsageRefresh() || UsageHistory() => Capability.viewUsage,
    _ => null,
  };
  return needed == null || grants.has(needed)
      ? null
      : 'this device was not granted ${needed.wire}';
}

/// [DataService]'s clock, as the conversation index asks for one.
final class _Clock implements core.Clock {
  const _Clock(this._now);

  final DateTime Function() _now;

  @override
  DateTime nowUtc() => _now().toUtc();
}
