import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_core/util.dart' show DirectoryChangeWatcher;
import 'package:karmashala_files/karmashala_files.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_terminal_core/profiles.dart' show TerminalProfile;
import 'package:karmashala_verification/verification.dart';
import 'package:karmashala_git/git.dart'
    show
        ReviewAnchor,
        ReviewAuthorKind,
        ReviewComment,
        ReviewThread,
        WorktreeSetup,
        WorktreeSetupReport,
        compareSetupRuns,
        defaultReviewStatus,
        reviewBodyOf;
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_git/git.dart'
    show
        AheadBehind,
        FileChange,
        FileDiffStat,
        GitCommit,
        GitPresence,
        GitWorktree,
        RepositoryOrigin,
        GitException,
        GitService,
        NotAGitRepository,
        RemoteRepo,
        WorkingTreeStatus,
        WorktreeCreationRecord;
import 'package:karmashala_git/github.dart'
    show
        BranchProtection,
        GitHubService,
        MergeStateStatus,
        WorkflowRun,
        boundRunLog,
        kUnknownForgePolicy;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_git/worktrees.dart' show WorktreeService;
import 'package:karmashala_session/delivery.dart' show SessionDelivery;
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:agent_cli/descriptors.dart'
    show
        AgentActivityStatus,
        AgentStatusReport,
        AgentStatusSource,
        AgentRegistry,
        AgentWaitKind;
import 'package:agent_cli/discovery.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show SessionSummary;
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart'
    show HandoffSourceBrief, SessionLink;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart' show AgentPaneLaunch;
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show MemoryPairedDeviceStore;
import 'package:karmashala_remote/remote.dart'
    show
        PairedDevice,
        pairedDeviceNameOf,
        pairedDeviceWithoutSecrets,
        sameRelay;
import 'package:store_console/store_console.dart'
    show Reading, StoreApp, StoreAppSnapshot, StoreKind;

import 'fake_command_runner.dart';

part 'fake_evidence.dart';
part 'fake_terminals_work.dart';
part 'fake_attention.dart';
part 'fake_session_work.dart';
part 'fake_hosts.dart';
part 'fake_sessions.dart';
part 'fake_pairings.dart';
part 'fake_worktrees.dart';
part 'fake_automations.dart';
part 'fake_conversations.dart';
part 'fake_agent_work.dart';
part 'fake_ssh_work.dart';
part 'fake_git_work.dart';
part 'fake_runs_work.dart';
part 'fake_files_work.dart';
part 'fake_env_vault.dart';
part 'fake_stores.dart';

/// **The one fake Karmashala server the app's tests talk to** — in memory,
/// no database, no `DataService`. It answers the data protocol the way the
/// server does as far as a client can tell: numbered writes (revisions),
/// changes told to every *other* subscribed link, refusals, and a server that
/// can stop and come back. Its domain rules are the shared ones in
/// `karmashala_notes`, `karmashala_projects`, `karmashala_session_engine` and
/// `karmashala_environments`; the server's own validation is tested in
/// `server/test/data/`, not here.
///
/// ```dart
/// final server = FakeDataServer();
/// final client = await server.connect();   // primed, torn down with the test
/// ProviderContainer(overrides: [dataClientProvider.overrideWithValue(client)]);
/// ```
class FakeDataServer {
  FakeDataServer({
    this.projects,
    Map<String, String>? projectOfRepository,
    Map<String, String>? repositoryOfSession,
    DateTime Function()? clock,
  }) : projectOfRepository = projectOfRepository ?? {},
       repositoryOfSession = repositoryOfSession ?? {},
       _now = clock ?? (() => DateTime.now().toUtc());

  /// The projects a note or todo may be filed under; null accepts any.
  final Set<String>? projects;

  /// The filing lookups the server makes from its own tables.
  final Map<String, String> projectOfRepository;
  final Map<String, String> repositoryOfSession;

  final DateTime Function() _now;

  final notes = <String, Note>{};
  final todos = <String, Todo>{};

  /// The activity log a range is read from.
  final activity = <ActivityEntry>[];
  final preferences = <String, String>{};

  /// The folders pinned to every file browser.
  List<QuickAccessPin> quickAccessPins = [];

  /// The workspace domain's four tables, shaped like the server's DAOs so a
  /// test seeds them the way the server's store is written. A write here
  /// after a client connected reaches it as another client's change.
  late final workspaceRows = FakeRows<Workspace>._(
    this,
    (row) => row.id,
    WorkspaceChanged.new,
    WorkspaceRemoved.new,
  );
  late final projectRows = FakeRows<Project>._(
    this,
    (row) => row.id,
    ProjectChanged.new,
    ProjectRemoved.new,
  );
  late final repositoryRows = FakeRows<Repository>._(
    this,
    (row) => row.id,
    RepositoryChanged.new,
    RepositoryRemoved.new,
  );
  late final sectionRows = FakeRows<StoredSection>._(
    this,
    (row) => row.id,
    SectionChanged.new,
    SectionRemoved.new,
  );

  /// The sessions domain, shaped like the server's DAOs: the rows (and the
  /// checkouts each spans), the imported history, and the records.
  late final sessionRows = FakeSessionRows._(this);
  late final sessionLinks = FakeSessionLinks._(this);
  late final importedRows = FakeImportedRows._(this);
  late final sessionRecords = FakeSessionRecords._(this);

  /// [sessionRecords], shaped like each of the server's record DAOs.
  late final eventRows = FakeEventRows._(sessionRecords);
  late final decisionRows = FakeDecisionRows._(sessionRecords);
  late final recapRows = FakeRecapRows._(sessionRecords);
  late final relayRows = FakeRelayRows._(sessionRecords);
  late final followUpRows = FakeFollowUpRows._(sessionRecords);

  /// Checkpoints (numbered per session), verification runs (kept whole, told
  /// by header) and comparisons, shaped like the server's DAOs.
  late final checkpointRows = FakeCheckpointRows._(this);

  /// What the server's checkpoint recorder would answer: captures, diffs,
  /// restores and skip reasons, scripted by a test.
  late final checkpointWork = FakeCheckpointWork._(this);
  late final verificationRows = FakeVerificationRows._(this);
  late final comparisonRows = FakeComparisonRows._(this);

  /// The sessions this server runs, so records the status of itself: a
  /// client's status for one is ignored and the row told back, as
  /// `SessionsHandler` does.
  final runsSessions = <String>{};

  /// Where agents run and who they run as, shaped like the server's DAOs:
  /// environments, saved SSH hosts, trusted keys (by `host:port`),
  /// installations, saved accounts (**with** their credentials, as the store
  /// keeps them — a client is only ever told them stripped) and the usage
  /// history.
  late final environmentRows = FakeHostRows<ExecutionEnvironment>._(
    this,
    (row) => row.id,
    EnvironmentChanged.new,
    (row) => EnvironmentRemoved(row.id),
    compareEnvironments,
  );
  late final sshHostRows = FakeHostRows<SshHost>._(
    this,
    (row) => row.id,
    (row) => SshHostTouched(row.id),
    (row) => SshHostRemoved(row.id),
    compareSshHosts,
  );
  late final knownHostRows = FakeHostRows<KnownHostKey>._(
    this,
    (row) => DataClient.knownHostKey(row.host, row.port),
    KnownHostChanged.new,
    (row) => KnownHostRemoved(row.host, row.port),
    compareKnownHosts,
  );
  late final installationRows = FakeHostRows<AgentInstallation>._(
    this,
    (row) => row.id,
    InstallationChanged.new,
    (row) => InstallationRemoved(row.id),
    compareInstallations,
  );
  late final acpAgentRows = FakeHostRows<AcpAgentRow>._(
    this,
    (row) => row.id,
    AcpAgentChanged.new,
    (row) => AcpAgentRemoved(row.id),
    (a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    },
  );
  late final claudeAccountRows = FakeHostRows<ClaudeAccount>._(
    this,
    (row) => row.id,
    (row) => ClaudeAccountChanged(claudeAccountWithoutCredentials(row)),
    (row) => ClaudeAccountRemoved(row.id),
    compareClaudeAccounts,
  );
  late final codexAccountRows = FakeHostRows<CodexAccount>._(
    this,
    (row) => row.id,
    (row) => CodexAccountChanged(codexAccountWithoutCredentials(row)),
    (row) => CodexAccountRemoved(row.id),
    compareCodexAccounts,
  );
  late final usageRows = FakeUsageRows._(this);

  /// The work the server does for its agents: usage it read, sign-ins,
  /// capture and switch, detection and the CLI import — scripted.
  late final agentWork = FakeAgentWork._(this);

  /// The server's own SSH: test connections, disconnects and the answers a
  /// window gives its questions — scripted.
  late final sshWork = FakeSshWork._(this);

  /// The git the server does — reads and writes of a checkout, worktrees,
  /// their cleanup, a project's folders, GitHub — scripted.
  late final gitWork = FakeGitWork._(this);

  /// The server's Flutter apps, hosted runs and browser — scripted.
  late final runs = FakeRunsWork._(this);

  /// A machine's files — listings, reads and saves, copies, Quick Open's
  /// index, watches — over real file spaces a test points at temp folders.
  final filesWork = FakeFilesWork._();

  /// Webhook secrets made and the calls a status read answers.
  final webhooks = FakeWebhooks();

  /// The server's environment vault, write-only, in memory.
  late final envVault = FakeEnvVault._(this);

  /// The server's app stores: credential summaries and what was read, in
  /// memory; no store is reached.
  late final stores = FakeStores._(this);

  /// The server's terminals: profiles, starts, records — nothing spawned.
  late final terminals = FakeTerminalsWork._(this);

  /// The server's session status and attention inbox (slice 5c): seeded by
  /// a test, told to every window.
  late final attention = FakeAttention._(this);

  /// The server's launch path: starts, resumes, handoffs, forks — nothing
  /// spawned; the rows it writes are told.
  late final sessionWork = FakeSessionWork._(this);

  /// The window a person last used, as `client.active` last said.
  String? focusedPaneId;

  /// The automations domain, shaped like the server's DAOs: automations,
  /// their runs, checks and origin chains; scheduled resumes; project checks
  /// and verification switches.
  late final automationRows = FakeAutomationRows._(this);
  late final resumeRows = FakeResumeRows._(this);
  late final projectCheckRows = FakeProjectCheckRows._(this);

  /// Where the rows' own tells go while a request is answered: its changes.
  List<DataChange>? _recordInto;

  /// The paired devices, keys and push tokens kept as the store keeps them.
  late final deviceRows = FakeDeviceRows._(this);

  /// The conversation index: turns a test seeds, found by plain words.
  final conversations = FakeConversations._();

  /// Worktree setups, their runs and review threads; snippets and presets.
  late final worktreeRows = FakeWorktreeRows._(this);
  late final snippetRows = FakeSnippetRows._(this);

  /// [preferences] as a store — for a test to seed before a client
  /// connects, or to read back what one wrote (once it has landed).
  late final PreferenceStore store = _MapStore(preferences);

  /// The number of the last write.
  int revision = 0;

  /// Every request answered, by kind, in order.
  final requests = <String>[];

  /// What agents showed, by id, and each revision's bytes — seeded through
  /// [showArtifact], as the server's library would hold them.
  final artifacts = <String, Artifact>{};
  final artifactBytes = <(String, int), Uint8List>{};

  /// When set, artifact content is refused with it.
  DataRefused? artifactContentRefusal;

  /// [artifact] at its revision holding [bytes], told to every client as the
  /// server tells a show or a rewrite.
  void showArtifact(Artifact artifact, List<int> bytes) {
    artifacts[artifact.id] = artifact;
    artifactBytes[(artifact.id, artifact.revision)] = Uint8List.fromList(bytes);
    _tell(null, [ArtifactChanged(artifact)]);
  }

  Object? _handleArtifacts(ArtifactsRequest<Object?> request) {
    Artifact known(String id) =>
        artifacts[id] ?? (throw DataRefused.notFound('no artifact has id $id'));
    switch (request) {
      case SessionArtifactsRead(:final sessionId):
        return [
          for (final a in artifacts.values)
            if (a.sessionId == sessionId) a,
        ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case ArtifactRevisionsRead(:final id):
        known(id);
        return [
          for (final key in artifactBytes.keys)
            if (key.$1 == id)
              ArtifactRevisionSummary(
                revision: key.$2,
                size: artifactBytes[key]!.length,
                capturedAt: DateTime.utc(2026, 10, 6),
              ),
        ]..sort((a, b) => a.revision.compareTo(b.revision));
      case ArtifactContentRead(
        :final id,
        :final revision,
        :final offset,
        :final length,
      ):
        final refusal = artifactContentRefusal;
        if (refusal != null) throw refusal;
        final artifact = known(id);
        final bytes =
            artifactBytes[(id, revision ?? artifact.revision)] ??
            (throw DataRefused.notFound('revision $revision is not kept'));
        final start = offset.clamp(0, bytes.length);
        final end = (start + length).clamp(0, bytes.length);
        return FileChunk(
          Uint8List.sublistView(bytes, start, end),
          fileSize: bytes.length,
        );
      case ArtifactSetNetwork(:final id, :final allowed):
        final next = known(id).copyWith(networkAllowed: allowed);
        artifacts[id] = next;
        // The server's library announces it, to the asking client too.
        _tell(null, [ArtifactChanged(next)]);
        return next;
    }
  }

  /// The modes each session's agent last announced (seeded through
  /// [writeAsAnotherClient]); `sessions.setMode` moves `currentModeId`.
  final sessionModes = <String, SessionModesChanged>{};

  /// When set, `sessions.setMode` is refused `invalid` with these words.
  String? modeRefusal;

  /// The config options each session's agent last announced (seeded through
  /// [writeAsAnotherClient]); `sessions.setConfigOption` moves `currentValue`.
  final sessionConfigOptions = <String, SessionConfigOptionsChanged>{};

  /// When set, `sessions.setConfigOption` is refused `invalid` with these
  /// words.
  String? configOptionRefusal;

  /// When set, answers wait for it — a slow server, or one mid-answer.
  Completer<void>? hold;

  final _links = <FakeDataLink>{};
  var _running = true;

  static final _byClient = Expando<FakeDataServer>();

  /// The server [client] was connected to by [connect] — for a test that
  /// holds only a container, or only its client.
  static FakeDataServer of(DataClient client) =>
      _byClient[client] ??
      (throw StateError('that client was not connected to a fake server'));

  /// A client of this server, primed, closed when the test ends. [wait] is
  /// how long its writes wait for a server that is down.
  Future<DataClient> connect({
    Duration wait = const Duration(seconds: 20),
    bool serverOnThisMachine = true,
  }) async {
    final client = await DataClient.connect(
      dial,
      waitForServer: wait,
      serverOnThisMachine: serverOnThisMachine,
    );
    _byClient[client] = this;
    addTearDown(client.close);
    return client;
  }

  /// [connect], as the override a test's container takes.
  Future<Override> override() async =>
      dataClientProvider.overrideWithValue(await connect());

  /// What a client dials: a new link, or nothing while stopped.
  Future<DataEndpoint?> dial() async {
    if (!_running) return null;
    final link = FakeDataLink._(this);
    _links.add(link);
    return link;
  }

  /// The server goes away: every link closes and nothing answers a dial.
  void stop() {
    _running = false;
    for (final link in [..._links]) {
      link._drop();
    }
  }

  /// It comes back; clients redial on their own backoff.
  void start() => _running = true;

  /// Another client's write, told to every subscribed link.
  void writeAsAnotherClient(List<DataChange> changes) {
    for (final change in changes) {
      switch (change) {
        case NoteChanged(:final note):
          notes[note.id] = note;
        case NoteRemoved(:final id):
          notes.remove(id);
        case TodoChanged(:final todo):
          todos[todo.id] = todo;
        // Not a row: nothing of it is kept.
        case AcpInstallProgress() || ActivityAppended():
          break;
        case TodoRemoved(:final id):
          todos.remove(id);
        case PreferenceChanged(:final key, :final value):
          value == null ? preferences.remove(key) : preferences[key] = value;
        case final RowChange row:
          _applyRow(row);
        case final SessionDomainChange change:
          _applySession(change);
        case final HostsDomainChange change:
          _applyHosts(change);
        case AcpAgentChanged(:final row):
          acpAgentRows._put(row);
        case AcpAgentRemoved(:final id):
          if (acpAgentRows.getById(id) case final row?) {
            acpAgentRows._remove(row);
          }
        case final WorktreesChange change:
          worktreeRows._apply(change);
        case final AutomationsChange change:
          automationRows._apply(change);
        case final SnippetsChange change:
          snippetRows._apply(change);
        case final EvidenceChange change:
          _applyEvidence(change);
        case PairingsChange():
          // Seed devices through [deviceRows]; a change carries no key.
          break;
        case SshChange() || RunsChange():
        // Nothing kept: told as it is.
        case GitChange():
          // Nothing kept: it says what to read again.
          break;
        case FilesChange() || TranscriptChanged() || ArtifactChange():
          // A watch's news is one link's.
          break;
        case SessionModesChanged(:final sessionId):
          sessionModes[sessionId] = change;
        case SessionConfigOptionsChanged(:final sessionId):
          sessionConfigOptions[sessionId] = change;
        case SessionQueueChanged():
          // Told, never kept: a client lists the queue again.
          break;
        case SessionAgentChanged():
          // Told, never kept: the row itself carries the agent.
          break;
        case SessionCommandsChanged():
          // Told, never kept: the agent's runtime greets them.
          break;
        case SessionNoticed():
          // Told once, never kept.
          break;
        case SessionPromptKindsChanged():
          // Told, never kept: the agent's runtime greets it.
          break;
        case SessionUsageChanged():
          // Told, never kept: a late client reads it from `sessions.stats`.
          break;
        case SessionActiveModelChanged():
          // Told, never kept: the server's keeper greets it.
          break;
        case EnvVariablesChanged():
          // Names only: seed a value through [envVault].
          break;
        case QuickAccessChanged(:final pins):
          quickAccessPins = [...pins];
        case StoresChanged() || StoresProgress() || StoreAppChanged():
          // Told by [stores] as it changes; a test seeds its view directly.
          break;
        case TerminalChanged(:final terminal):
          terminals.records[terminal.sessionId] = terminal;
        case TerminalRemoved(:final sessionId):
          terminals.records.remove(sessionId);
        case SessionStatusChanged(:final entry):
          attention.statuses[entry.openId] = entry;
        case SessionStatusRemoved(:final openId):
          attention.statuses.remove(openId);
        case WatchCoverageChanged(:final coverage):
          attention.coverage = coverage;
        case InboxChanged(:final snapshot):
          attention.inbox = snapshot.inbox;
          attention.waiting = snapshot.waiting;
        case ForgeReadingChanged(:final checkout, :final reading):
          attention.forgeReadings[checkout] = reading;
        case AttentionNewsTold() || InboxOpenWanted() || UsageLimitNoticed():
        // Nothing kept: told as it is.
        case ClientIntent():
          // Told to a window, never kept.
          break;
      }
    }
    _tell(null, changes);
  }

  void _applyHosts(HostsDomainChange change) {
    switch (change) {
      case EnvironmentChanged(:final environment):
        environmentRows._put(environment);
      case EnvironmentRemoved(:final id):
        if (environmentRows.getById(id) case final row?) {
          environmentRows._remove(row);
        }
      case InstallationChanged(:final installation):
        installationRows._put(installation);
      case InstallationRemoved(:final id):
        if (installationRows.getById(id) case final row?) {
          installationRows._remove(row);
        }
      case KnownHostChanged(:final key):
        knownHostRows._put(key);
      case KnownHostRemoved(:final host, :final port):
        if (knownHostRows.find(host, port) case final key?) {
          knownHostRows._remove(key);
        }
      case SshHostRemoved(:final id):
        sshHostRows._rows.remove(id);
      case SshHostTouched() ||
          ClaudeAccountChanged() ||
          ClaudeAccountRemoved() ||
          CodexAccountChanged() ||
          CodexAccountRemoved() ||
          UsageRecorded():
        // Seed these through their tables; a change alone says too little.
        break;
      case UsageStateChanged(:final state):
        agentWork.usage[state.accountKey] = state;
    }
  }

  void _applySession(SessionDomainChange change) {
    final ignored = <DataChange>[];
    switch (change) {
      case SessionRowChanged(:final session):
        sessionRows._put(session, ignored);
      case SessionRowRemoved(:final id):
        sessionRows._remove(id, ignored);
      case SessionLinksChanged(:final sessionId, :final links):
        sessionLinks._links[sessionId] = [...links];
      case ImportedChanged(:final session):
        importedRows._rows[session.id] = session;
      case ImportedRemoved(:final id):
        importedRows._rows.remove(id);
      case DecisionRecorded(:final decision):
        sessionRecords.decisions[decision.id!] = decision;
      case DecisionRemoved(:final id):
        sessionRecords.decisions.remove(id);
      case RecapChanged(:final recap):
        sessionRecords.recaps[recap.sessionId] = recap;
      case RecapRemoved(:final sessionId):
        sessionRecords.recaps.remove(sessionId);
      case FollowUpChanged(:final followUp):
        sessionRecords.followUps[followUp.id!] = followUp;
    }
  }

  void _applyRow(RowChange change) => switch (change) {
    WorkspaceChanged(:final workspace) => workspaceRows._put(workspace),
    ProjectChanged(:final project) => projectRows._put(project),
    RepositoryChanged(:final repository) => repositoryRows._put(repository),
    SectionChanged(:final section) => sectionRows._put(section),
    WorkspaceRemoved(:final id) => workspaceRows._remove(id),
    ProjectRemoved(:final id) => projectRows._remove(id),
    RepositoryRemoved(:final id) => repositoryRows._remove(id),
    SectionRemoved(:final id) => sectionRows._remove(id),
  };

  static Project _withWorkspace(Project project, String? workspaceId) =>
      Project(
        id: project.id,
        name: project.name,
        root: project.root,
        createdAt: project.createdAt,
        workspaceId: workspaceId,
        defaultRepositoryId: project.defaultRepositoryId,
      );

  static Project _withDefault(Project project, String? repositoryId) => Project(
    id: project.id,
    name: project.name,
    root: project.root,
    createdAt: project.createdAt,
    workspaceId: project.workspaceId,
    defaultRepositoryId: repositoryId,
  );

  void _tell(FakeDataLink? origin, List<DataChange> changes) {
    if (changes.isEmpty) return;
    final recording = _recordInto;
    if (origin == null && recording != null) {
      recording.addAll(changes);
      return;
    }
    final batch = DataChanges(++revision, List.unmodifiable(changes));
    for (final link in _links) {
      if (link != origin && link._subscribed) link._changes.add(batch);
    }
    // The server files what a follow-up says in its inbox (slice 5c).
    if (changes.any((change) => change is FollowUpChanged)) {
      attention._syncFollowUps();
    }
  }

  DataReply<R> _handle<R>(FakeDataLink origin, DataRequest<R> request) {
    requests.add(request.kind);
    if (request case SessionSetMode(:final sessionId, :final modeId)) {
      if (modeRefusal case final words?) throw DataRefused.invalid(words);
      final before = sessionModes[sessionId];
      final after = SessionModesChanged(
        sessionId: sessionId,
        currentModeId: modeId,
        availableModes: before?.availableModes ?? const [],
      );
      sessionModes[sessionId] = after;
      _tell(null, [after]);
      return DataReply(const DataAck() as R, revision, const []);
    }
    if (request case SessionSetConfigOption(
      :final sessionId,
      :final configId,
      :final value,
    )) {
      if (configOptionRefusal case final words?) {
        throw DataRefused.invalid(words);
      }
      final before = sessionConfigOptions[sessionId];
      final after = SessionConfigOptionsChanged(
        sessionId: sessionId,
        options: [
          for (final option in before?.options ?? const <SessionConfigOption>[])
            option.id == configId
                ? SessionConfigOption(
                    id: option.id,
                    name: option.name,
                    type: option.type,
                    description: option.description,
                    category: option.category,
                    currentValue: value,
                    choices: option.choices,
                  )
                : option,
        ],
      );
      sessionConfigOptions[sessionId] = after;
      _tell(null, [after]);
      return DataReply(const DataAck() as R, revision, const []);
    }
    if (request case final SshWorkRequest<Object?> work) {
      return DataReply(sshWork._handle(work) as R, revision, const []);
    }
    if (request case final EnvVaultRequest<Object?> work) {
      return DataReply(envVault._handle(work) as R, revision, const []);
    }
    if (request case final StoreRequest<Object?> work) {
      return DataReply(stores._handle(work) as R, revision, const []);
    }
    if (request case final TerminalWorkRequest<Object?> work) {
      return DataReply(terminals._handle(work) as R, revision, const []);
    }
    if (request case final AttentionRequest<Object?> work) {
      return DataReply(
        attention._handle(work, origin) as R,
        revision,
        const [],
      );
    }
    if (request case final WebhooksWorkRequest<Object?> work) {
      return DataReply(webhooks._handle(work) as R, revision, const []);
    }
    if (request case final ChecksRun work) {
      return DataReply(attention._checks(work) as R, revision, const []);
    }
    if (request case final SessionWorkRequest<Object?> work) {
      return DataReply(sessionWork._handle(work) as R, revision, const []);
    }
    if (request case ClientActive(:final focusedPaneId)) {
      this.focusedPaneId = focusedPaneId;
      return DataReply(const DataAck() as R, revision, const []);
    }
    if (request case final FlutterWorkRequest<Object?> work) {
      return DataReply(runs._flutter(work) as R, revision, const []);
    }
    if (request case final BrowserWorkRequest<Object?> work) {
      return DataReply(runs._browser(work) as R, revision, const []);
    }
    if (request case final AgentWorkRequest<Object?> work) {
      // Agent work is answered when done, and what it wrote is told to every
      // link — the asker's too — as the server announces it.
      final written = <DataChange>[];
      final result = agentWork._handle(work, written);
      _tell(null, written);
      return DataReply(result as R, revision, const []);
    }
    final changes = <DataChange>[];
    final Object? result = switch (request) {
      DataSubscribe() => _subscribe(origin),
      final AutomationsRequest<Object?> r => automationRows._handle(r, changes),
      final PairingsRequest<Object?> r => deviceRows._handle(r, changes),
      final ConversationsRequest<Object?> r => conversations._handle(r),
      final WorktreesRequest<Object?> r => worktreeRows._handle(r, changes),
      final SnippetsRequest<Object?> r => snippetRows._handle(r, changes),
      final QuickAccessRequest r => _quickAccess(r, changes),
      final CheckpointsRequest<Object?> r => checkpointRows._handle(r, changes),
      final CheckpointWorkRequest<Object?> r => checkpointWork._handle(r),
      final VerificationRequest<Object?> r => verificationRows._handle(
        r,
        changes,
      ),
      final ComparisonsRequest<Object?> r => comparisonRows._handle(r, changes),
      NotesList(:final sessionId) => [
        for (final note in notes.values)
          if (sessionId == null || note.sourceSessionId == sessionId) note,
      ]..sort(compareNotes),
      final NoteCapture r => _capture(r, changes),
      final NoteEdit r => _changedNote(
        _note(r.id).copyWith(
          body: r.body,
          title: noteTitleOf(r.title),
          clearTitle: noteTitleOf(r.title) == null,
          projectId: _project(r.projectId),
          clearProjectId: r.projectId == null,
          updatedAt: _now(),
        ),
        changes,
      ),
      final NoteFile r => _changedNote(
        _note(r.id).copyWith(
          projectId: _project(r.projectId),
          clearProjectId: r.projectId == null,
        ),
        changes,
      ),
      NoteDelete(:final id) => _removeNote(id, changes),
      TodosList() => [...todos.values]..sort(compareTodos),
      final TodoAdd r => _add(r, changes),
      final TodoSetDone r => _setDone(r, changes),
      final TodoEdit r => _changedTodo(
        _todo(r.id).copyWith(body: _body(r.body)),
        changes,
      ),
      final TodoFile r => _changedTodo(
        _todo(r.id).copyWith(
          projectId: _project(r.projectId),
          clearProjectId: r.projectId == null,
        ),
        changes,
      ),
      final TodoMove r => _move(r, changes),
      TodoDelete(:final id) => _removeTodo(id, changes),
      TodosClearDone(:final ids) => _clearDone(ids, changes),
      PreferencesGet() => Map.of(preferences),
      PreferenceSet(:final key, :final value) => _setPreference(
        key,
        value,
        changes,
      ),
      PreferenceRemove(:final key) => _setPreference(key, null, changes),
      WorkspaceList() => WorkspaceSnapshot(
        workspaces: workspaceRows.getAll(),
        projects: projectRows.getAll(),
        repositories: repositoryRows.getAll(),
        sections: sectionRows.getAll(),
      ),
      final WorkspacePut r => _putWorkspace(r, changes),
      final WorkspaceSetColor r => _rowChanged(
        changes,
        _workspace(r.id).copyWith(color: r.color, clearColor: r.color == null),
      ),
      WorkspaceDelete(:final id) => _deleteWorkspace(id, changes),
      final ProjectCreate r => _createProject(r, changes),
      final ProjectUpdate r => _updateProject(r, changes),
      ProjectsFile(:final placements) => _fileProjects(placements, changes),
      ProjectDelete(:final id) => _deleteProject(id, changes),
      ProjectsUsingEnvironment(:final environmentId) => [
        for (final p in projectRows.getAll())
          if (p.environmentId == environmentId) p.name,
      ],
      final CheckoutsAdd r => _addCheckouts(r, changes),
      CheckoutsRetire(:final ids) => _retireCheckouts(ids, changes),
      final CheckoutsIdentify r => _identify(r, changes),
      SectionPut(:final section) => _rowChanged(changes, section),
      SectionsReorder(:final ids) => _reorderSections(ids, changes),
      SectionDelete(:final id) => _deleteSection(id, changes),
      SessionsList() ||
      SessionCreate() ||
      SessionEdit() ||
      SessionDelete() ||
      SessionsDeleteMany() ||
      SessionsArchive() ||
      SessionsUnarchive() ||
      SessionLinkAdd() ||
      SessionLinkRemove() ||
      SessionEvents() ||
      SessionEventsLatest() ||
      SessionEventsAppend() ||
      DecisionAppend() ||
      RecapWrite() ||
      RecapDismiss() ||
      RelayRecord() ||
      RelaysTo() ||
      RelayCount() ||
      FollowUpRaise() ||
      FollowUpResolve() ||
      ImportedAdd() ||
      ImportedRename() ||
      ImportedDelete() => _handleSessions(request, changes),
      EnvironmentsList() ||
      EnvironmentPut() ||
      SshHostPut() ||
      SshHostDelete() ||
      KnownHostTrust() ||
      KnownHostForget() ||
      AgentsList() ||
      InstallationSetPath() ||
      ClaudeAccountDelete() ||
      CodexAccountDelete() ||
      UsageHistory() => _handleHosts(request, changes),
      final AcpAgentsRequest r => _handleAcpAgents(r, changes),
      final ActivityRange r => ActivityPage(
        entries: [
          for (final entry in activity)
            if (!entry.at.isBefore(r.from) &&
                entry.at.isBefore(r.to) &&
                (r.projectIds?.contains(entry.projectId) ?? true))
              entry,
        ],
      ),
      AgentWorkRequest() ||
      FlutterWorkRequest() ||
      BrowserWorkRequest() ||
      SshWorkRequest() ||
      TerminalWorkRequest() ||
      AttentionRequest() ||
      ChecksWorkRequest() ||
      WebhooksWorkRequest() ||
      SessionWorkRequest() ||
      ClientActive() ||
      EnvVaultRequest() => throw StateError('answered above'),
      GitWorkRequest() ||
      FilesWorkRequest() => throw StateError('answered in FakeDataLink.send'),
      SessionTranscriptRequest() => throw const DataRefused.unavailable(
        'this fake reads no transcripts',
      ),
      final ArtifactsRequest<Object?> r => _handleArtifacts(r),
      final SessionInputRequest<Object?> r => sessionWork._input(r),
      SessionSetMode() ||
      SessionSetConfigOption() ||
      StoreRequest() => throw StateError('answered above'),
    };
    _tell(origin, changes);
    return DataReply(result as R, revision, List.unmodifiable(changes));
  }

  // The workspace domain.

  var _ids = 0;
  String _freshId(String prefix) => '$prefix-fake-${++_ids}';

  /// Sessions, their links and imported history recorded on checkout [id].
  int _sessionHistoryOn(String id) => {
    for (final s in sessionRows.getAll())
      if (s.repositoryId == id ||
          sessionLinks.linksFor(s.id).any((l) => l.repositoryId == id))
        s.id,
    for (final i in importedRows._rows.values)
      if (i.repositoryId == id) i.id,
  }.length;

  /// Other records that keep a checkout from being retired, by its id — what
  /// else the server counts in history (comparisons).
  final historyReferences = <String, int>{};

  Workspace _workspace(String id) =>
      workspaceRows.getById(id) ??
      (throw DataRefused.notFound('no context with id $id'));

  Project _existingProject(String id) =>
      projectRows.getById(id) ??
      (throw DataRefused.notFound('no project with id $id'));

  T _rowChanged<T extends Object>(List<DataChange> changes, T row) {
    changes.add(_rowTable(row)._put(row));
    return row;
  }

  FakeRows<Object> _rowTable(Object row) => switch (row) {
    Workspace() => workspaceRows,
    Project() => projectRows,
    Repository() => repositoryRows,
    StoredSection() => sectionRows,
    _ => throw ArgumentError('not a workspace row: $row'),
  };

  Workspace _putWorkspace(WorkspacePut r, List<DataChange> changes) {
    final name =
        rowNameOf(r.workspaceName) ??
        (throw const DataRefused.invalid('A context needs a name.'));
    for (final other in workspaceRows.getAll()) {
      if (other.id != r.id && sameContextName(other.name, name)) {
        throw DataRefused.invalid('A context called "$name" already exists.');
      }
    }
    final existing = workspaceRows.getById(r.id);
    return _rowChanged(
      changes,
      Workspace(
        id: r.id,
        name: name,
        description: descriptionOf(r.description),
        color: existing?.color,
        createdAt: existing?.createdAt ?? _now(),
      ),
    );
  }

  DataAck _deleteWorkspace(String id, List<DataChange> changes) {
    _workspace(id);
    changes.add(workspaceRows._remove(id));
    for (final project in projectRows.getAll()) {
      if (project.workspaceId == id) {
        _rowChanged(changes, _withWorkspace(project, null));
      }
    }
    return const DataAck();
  }

  ProjectCheckouts _createProject(ProjectCreate r, List<DataChange> changes) {
    final name =
        rowNameOf(r.projectName) ??
        (throw const DataRefused.invalid('A project needs a name.'));
    if (r.workspaceId case final id?) _workspace(id);
    final project = _rowChanged(
      changes,
      Project(
        id: _freshId('project'),
        name: name,
        root: r.root,
        createdAt: _now(),
        workspaceId: r.workspaceId,
      ),
    );
    final checkouts = checkoutsForNewProject(
      project,
      r.found,
      newId: () => _freshId('repository'),
    );
    for (final checkout in checkouts) {
      _rowChanged(changes, checkout);
    }
    return ProjectCheckouts(project, checkouts);
  }

  ProjectUpdated _updateProject(ProjectUpdate r, List<DataChange> changes) {
    final project = _existingProject(r.id);
    final name = r.projectName == null
        ? project.name
        : (rowNameOf(r.projectName!) ??
              (throw const DataRefused.invalid('A project needs a name.')));
    final root = r.root;
    var rebased = const <Repository>[];
    var leftBehind = const <Repository>[];
    var added = const <Repository>[];
    if (root != null && rootMoves(project.root, root)) {
      (:rebased, :leftBehind) = rebaseCheckouts(
        project.root,
        root,
        repositoryRows.getByProject(project.id),
      );
      for (final row in rebased) {
        _rowChanged(changes, row);
      }
      added = checkoutsToAdd(
        project,
        [...rebased, ...leftBehind],
        r.found,
        newId: () => _freshId('repository'),
        now: _now(),
      );
      for (final row in added) {
        _rowChanged(changes, row);
      }
    }
    final wanted = r.clearDefaultRepository
        ? null
        : (r.defaultRepositoryId ?? project.defaultRepositoryId);
    final owned = repositoryRows
        .getByProject(project.id)
        .any((checkout) => checkout.id == wanted);
    final updated = _rowChanged(
      changes,
      Project(
        id: project.id,
        name: name,
        root: root ?? project.root,
        createdAt: project.createdAt,
        workspaceId: project.workspaceId,
        defaultRepositoryId: owned ? wanted : null,
      ),
    );
    return ProjectUpdated(
      project: updated,
      rebased: rebased,
      leftBehind: leftBehind,
      discovered: added,
    );
  }

  DataAck _fileProjects(
    Map<String, String?> placements,
    List<DataChange> changes,
  ) {
    placements.forEach((projectId, workspaceId) {
      final project = _existingProject(projectId);
      if (workspaceId != null) _workspace(workspaceId);
      _rowChanged(changes, _withWorkspace(project, workspaceId));
    });
    return const DataAck();
  }

  DataAck _deleteProject(String id, List<DataChange> changes) {
    _existingProject(id);
    final checkouts = {
      for (final checkout in repositoryRows.getByProject(id)) checkout.id,
    };
    // The schema's cascade: the sessions on those checkouts and the history
    // they hold go with them.
    for (final session in sessionRows.getAll()) {
      if (checkouts.contains(session.repositoryId)) {
        _deleteSession(session.id, changes);
      }
    }
    for (final imported in [...importedRows._rows.values]) {
      if (checkouts.contains(imported.repositoryId)) {
        importedRows._rows.remove(imported.id);
        changes.add(ImportedRemoved(imported.id));
      }
    }
    worktreeRows._checkoutsGoing(checkouts, changes);
    changes.addAll(projectRows._removeCascading(id));
    for (final note in [...notes.values]) {
      if (note.projectId == id) {
        _changedNote(note.copyWith(clearProjectId: true), changes);
      }
    }
    for (final todo in [...todos.values]) {
      if (todo.projectId == id) {
        _changedTodo(todo.copyWith(clearProjectId: true), changes);
      }
    }
    return const DataAck();
  }

  List<Repository> _addCheckouts(CheckoutsAdd r, List<DataChange> changes) {
    final project = _existingProject(r.projectId);
    final added = checkoutsToAdd(
      project,
      repositoryRows.getByProject(project.id),
      r.found,
      newId: () => _freshId('repository'),
      orRoot: r.orRoot,
      now: _now(),
    );
    for (final row in added) {
      _rowChanged(changes, row);
    }
    return added;
  }

  Map<String, int> _retireCheckouts(
    List<String> ids,
    List<DataChange> changes,
  ) {
    final answer = <String, int>{};
    for (final id in ids) {
      final checkout = repositoryRows.getById(id);
      if (checkout == null) continue;
      final records = answer[id] =
          (historyReferences[id] ?? 0) + _sessionHistoryOn(id);
      if (records > 0) continue;
      changes.add(repositoryRows._remove(id));
      worktreeRows._checkoutsGoing({id}, changes);
      final project = projectRows.getById(checkout.projectId);
      if (project != null && project.defaultRepositoryId == id) {
        _rowChanged(changes, _withDefault(project, null));
      }
    }
    return answer;
  }

  List<Repository> _identify(CheckoutsIdentify r, List<DataChange> changes) => [
    for (final row in repositoryRows.getAll())
      if (Checkout(row.path) == Checkout(r.path) &&
          row.canonicalId != r.canonicalId)
        _rowChanged(
          changes,
          Repository(
            id: row.id,
            projectId: row.projectId,
            name: row.name,
            path: row.path,
            createdAt: row.createdAt,
            canonicalId: r.canonicalId,
          ),
        ),
  ];

  List<StoredSection> _reorderSections(
    List<String> ids,
    List<DataChange> changes,
  ) {
    for (var i = 0; i < ids.length; i++) {
      final section = sectionRows.getById(ids[i]);
      if (section != null && section.position != i) {
        _rowChanged(changes, section.copyWith(position: i));
      }
    }
    return sectionRows.getAll()..sort(compareSections);
  }

  DataAck _deleteSection(String id, List<DataChange> changes) {
    if (sectionRows.getById(id) == null) {
      throw DataRefused.notFound('no section with id $id');
    }
    changes.add(sectionRows._remove(id));
    return const DataAck();
  }

  DataAck _subscribe(FakeDataLink origin) {
    origin._subscribed = true;
    // What the server keeps now, told to this window alone as it joins.
    origin.tell(attention._greeting());
    return const DataAck();
  }

  String? _project(String? id) {
    if (id != null && !(projects?.contains(id) ?? true)) {
      throw DataRefused.notFound('no project with id $id');
    }
    return id;
  }

  void _newId(String id, bool taken) {
    final problem = recordIdProblem(id);
    if (problem != null) throw DataRefused.invalid(problem);
    if (taken) throw DataRefused.invalid('id $id is taken');
  }

  Note _note(String id) =>
      notes[id] ?? (throw DataRefused.notFound('no note with id $id'));

  Todo _todo(String id) =>
      todos[id] ?? (throw DataRefused.notFound('no todo with id $id'));

  String _body(String body) =>
      todoBodyOf(body) ?? (throw const DataRefused.invalid('a todo is blank'));

  Note _capture(NoteCapture r, List<DataChange> changes) {
    _newId(r.id, notes.containsKey(r.id));
    final session = r.sourceSessionId;
    final repository =
        r.sourceRepositoryId ??
        (session == null ? null : repositoryOfSession[session]);
    final project =
        r.projectId ??
        (r.inheritProject && repository != null
            ? projectOfRepository[repository]
            : null);
    final now = _now();
    return _changedNote(
      Note(
        id: r.id,
        title: noteTitleOf(r.title),
        body: r.body,
        projectId: _project(project),
        sourceSessionId: session,
        sourceRepositoryId: repository,
        sourceMessageOrdinal: r.sourceMessageOrdinal,
        sourceMessageRole: r.sourceMessageRole,
        createdAt: now,
        updatedAt: now,
      ),
      changes,
    );
  }

  Note _changedNote(Note note, List<DataChange> changes) {
    notes[note.id] = note;
    changes.add(NoteChanged(note));
    return note;
  }

  DataAck _removeNote(String id, List<DataChange> changes) {
    _note(id);
    notes.remove(id);
    changes.add(NoteRemoved(id));
    return const DataAck();
  }

  Todo _add(TodoAdd r, List<DataChange> changes) {
    _newId(r.id, todos.containsKey(r.id));
    final body = _body(r.body);
    final fromSession = r.projectOfSession;
    final repository = fromSession == null
        ? null
        : repositoryOfSession[fromSession];
    return _changedTodo(
      Todo(
        id: r.id,
        body: body,
        projectId: _project(
          r.projectId ??
              (repository == null ? null : projectOfRepository[repository]),
        ),
        position: nextTodoPosition(todos.values),
        createdAt: _now(),
      ),
      changes,
    );
  }

  Todo _setDone(TodoSetDone r, List<DataChange> changes) {
    final todo = _todo(r.id);
    if (todo.isDone == r.done) return todo;
    return _changedTodo(
      r.done ? todo.copyWith(doneAt: _now()) : todo.copyWith(clearDoneAt: true),
      changes,
    );
  }

  Todo _changedTodo(Todo todo, List<DataChange> changes) {
    todos[todo.id] = todo;
    changes.add(TodoChanged(todo));
    return todo;
  }

  List<Todo> _move(TodoMove r, List<DataChange> changes) {
    _todo(r.id);
    final order = openOrderAfterMove(todos.values, r.id, up: r.up);
    for (var i = 0; i < (order?.length ?? 0); i++) {
      final todo = todos[order![i]]!;
      if (todo.position != i) _changedTodo(todo.copyWith(position: i), changes);
    }
    return [...todos.values]..sort(compareTodos);
  }

  DataAck _removeTodo(String id, List<DataChange> changes) {
    _todo(id);
    todos.remove(id);
    changes.add(TodoRemoved(id));
    return const DataAck();
  }

  int _clearDone(List<String> ids, List<DataChange> changes) {
    final going = [
      for (final id in ids)
        if (todos[id]?.isDone ?? false) id,
    ];
    for (final id in going) {
      todos.remove(id);
      changes.add(TodoRemoved(id));
    }
    return going.length;
  }

  /// The quick-access pins, kept as the server keeps them: in order, one per
  /// folder, each change told whole.
  List<QuickAccessPin> _quickAccess(
    QuickAccessRequest request,
    List<DataChange> changes,
  ) {
    final pins = [...quickAccessPins];
    switch (request) {
      case QuickAccessList():
        return pins;
      case QuickAccessPinFolder(:final pin):
        if (!pins.any(pin.sameFolder)) pins.add(pin);
      case QuickAccessUnpin(:final environmentId, :final path):
        final at = QuickAccessPin(environmentId: environmentId, path: path);
        pins.removeWhere(at.sameFolder);
      case QuickAccessRename(:final environmentId, :final path, :final label):
        final at = QuickAccessPin(environmentId: environmentId, path: path);
        final index = pins.indexWhere(at.sameFolder);
        if (index >= 0) pins[index] = pins[index].withLabel(label);
    }
    quickAccessPins = pins;
    changes.add(QuickAccessChanged(List.unmodifiable(pins)));
    return pins;
  }

  DataAck _setPreference(String key, String? value, List<DataChange> changes) {
    final problem =
        PreferenceKeys.keyProblem(key) ??
        (value == null ? null : PreferenceKeys.valueProblem(value));
    if (problem != null) throw DataRefused.invalid(problem);
    if (PreferenceKeys.isReserved(key)) {
      throw DataRefused(DataRefusalCode.reserved, '"$key" is not a preference');
    }
    value == null ? preferences.remove(key) : preferences[key] = value;
    changes.add(PreferenceChanged(key, value));
    return const DataAck();
  }
}

/// One workspace table of a [FakeDataServer], in memory.
class FakeRows<T extends Object> {
  FakeRows._(this._server, this._idOf, this._changed, this._removed);

  final FakeDataServer _server;
  final String Function(T row) _idOf;
  final RowChange Function(T row) _changed;
  final RowChange Function(String id) _removed;
  final _rows = <String, T>{};

  T? getById(String id) => _rows[id];

  List<T> getAll() => [..._rows.values];

  void insert(T row) => _server._tell(null, [_put(row)]);

  void update(T row) => insert(row);

  /// Removes [id]; a project takes its checkouts with it, as the schema's
  /// cascade does.
  void delete(String id) => _server._tell(null, _removeCascading(id));

  RowChange _put(T row) {
    _rows[_idOf(row)] = row;
    return _changed(row);
  }

  RowChange _remove(String id) {
    _rows.remove(id);
    return _removed(id);
  }

  List<RowChange> _removeCascading(String id) => [
    if (identical(this, _server.projectRows))
      for (final checkout in _server.repositoryRows.getByProject(id))
        _server.repositoryRows._remove(checkout.id),
    _remove(id),
  ];
}

extension FakeWorkspaceRows on FakeRows<Workspace> {
  void updateColor(String id, String? color) =>
      update(getById(id)!.copyWith(color: color, clearColor: color == null));
}

extension FakeProjectRows on FakeRows<Project> {
  void setWorkspace(String id, String? workspaceId) =>
      update(FakeDataServer._withWorkspace(getById(id)!, workspaceId));

  void setDefaultRepository(String id, String? repositoryId) =>
      update(FakeDataServer._withDefault(getById(id)!, repositoryId));
}

extension FakeRepositoryRows on FakeRows<Repository> {
  List<Repository> getByProject(String projectId) => [
    for (final row in getAll())
      if (row.projectId == projectId) row,
  ]..sort(compareRepositories);
}

extension FakeSectionRows on FakeRows<StoredSection> {
  void put(StoredSection section) => insert(section);
}

class _MapStore implements PreferenceStore {
  _MapStore(this._map);

  final Map<String, String> _map;

  @override
  String? read(String key) => _map[key];

  @override
  void write(String key, String value) => _map[key] = value;

  @override
  void remove(String key) => _map.remove(key);
}

/// One client's link to a [FakeDataServer], asynchronous like a socket.
class FakeDataLink implements DataEndpoint {
  FakeDataLink._(this._server);

  final FakeDataServer _server;
  final _changes = StreamController<DataChanges>.broadcast(sync: true);
  final _done = Completer<void>();
  var _subscribed = false;

  @override
  Future<DataReply<R>> send<R>(DataRequest<R> request) async {
    await _server.hold?.future;
    if (_done.isCompleted) {
      throw const DataRefused.unavailable('the link closed');
    }
    if (request case final GitWorkRequest<Object?> git) {
      // Answered when done, as the server does; what it moved is told to
      // every link, this one too. Counted in `gitWork.asked`, apart from
      // the data requests a copy's cost is measured by.
      final value = await _server.gitWork._handle(git);
      return DataReply(value as R, _server.revision, const []);
    }
    if (request case final FilesWorkRequest<Object?> files) {
      // Answered when done; a watch this link placed is told to it alone.
      final value = await _server.filesWork._handle(files, this);
      return DataReply(value as R, _server.revision, const []);
    }
    return _server._handle(this, request);
  }

  /// A change for this link alone — a path it watches moved.
  void tell(List<DataChange> changes) {
    if (_done.isCompleted || _changes.isClosed) return;
    _changes.add(DataChanges(_server.revision, List.unmodifiable(changes)));
  }

  @override
  Stream<DataChanges> get changes => _changes.stream;

  @override
  Stream<DataStreamItems> openStream(String source, String key) =>
      _server.runs._open(source, key);

  @override
  Future<void> get done => _done.future;

  void _drop() {
    _server._links.remove(this);
    _server.filesWork._closed(this);
    _server.attention._closed(this);
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    _drop();
    await _changes.close();
  }
}

/// The server's webhooks as a test sets them: each rotate makes a new secret,
/// and a status read answers [calls] and [url].
class FakeWebhooks {
  final rotated = <String>[];
  String? url = 'https://relay.example.com/h/0123/abcd';
  bool listening = true;
  List<WebhookCall> calls = [];

  Object _handle(WebhooksWorkRequest<Object?> request) => switch (request) {
    WebhookRotate(:final automationId) => () {
      rotated.add(automationId);
      return WebhookIssued(
        automationId: automationId,
        hookId: 'hook-$automationId',
        url: url,
        secret: 'whsec_test_${rotated.length}',
      );
    }(),
    WebhookStatusRead() => WebhookStatus(
      url: url,
      listening: listening,
      problem: listening ? null : 'This server has no relay to take calls on.',
      calls: calls,
    ),
  };
}
