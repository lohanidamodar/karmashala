import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AgentRegistry, AgentStatusReport;
import 'package:karmashala_notifications/attention.dart'
    show InboxItem, InboxItemKind;
import 'package:agent_cli/discovery.dart' show SystemClock;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart'
    show CliStoreLocator, ConversationPresence, ConversationStoreIndex;
import 'package:agent_cli/usage.dart' show AgentUsageService, UsageSample;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_companion_server/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart'
    show DiscoveredRepository, Repository;
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart' show Session;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:path/path.dart' as p;

import '../automations/daemon_checkout_facts.dart';
import '../automations/hosted_agent_launcher.dart';
import '../automations/session_mcp_access.dart';
import '../data/data_service.dart';
import '../domain/session_registry.dart';
import '../domain/uuid.dart';
import '../sessions/session_records.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import '../status/daemon_prompt_answers.dart';
import 'companion_handler.dart';
import 'daemon_session_control.dart';
import 'daemon_worktrees.dart';
import 'local_relay.dart';
import 'registry_screens.dart';
import 'package:karmashala_session_engine/store.dart';

/// The phone companion, served by the daemon: the one companion server on a
/// machine, running whether or not a desktop is.
///
/// It runs `RemoteHostService` — pairing, sealed channels, the LAN listener and
/// beacon, relay listeners, push — on the shared store's paired devices, with
/// the bindings `hostCompanionBindings` composes: every call answered here,
/// from the store, the server's attention and its own screens (slice 5c:
/// nothing is forwarded to a desktop). How it serves is the server's own
/// config (`server.json`, [config]), which the desktop's Remote access
/// settings write through `server.config.set` and [reconfigure] applies at
/// once. That includes the LAN relay phones on this network meet it at
/// (`companion.localRelay`): the server hosts it itself ([ServerLocalRelay])
/// and listens through it, so nothing a phone reaches depends on a desktop
/// app running.
class DaemonCompanion implements CompanionHandler {
  DaemonCompanion({
    required this.database,
    required this.registry,
    required this.hostName,
    this.dataDirectory,
    int lanPort = kHostCompanionPort,
    String lanAddress = '127.0.0.1',
    CompanionConfig config = CompanionConfig.off,
    bool localRelayEnabled = false,
    int localRelayPort = kDefaultLocalRelayPort,
    ServerLocalRelay? localRelay,
    LanInterfaceLister? lanInterfaces,
    this.transcriptPollInterval = const Duration(seconds: 2),
    RelayTransportFactory? relayFactory,
    PushPost? pushPost,
    CompanionScreens? screens,
    this.prompts,
    this.onLog,
    DateTime Function()? clock,
    String Function()? newId,
    bool? windows,
    AgentUsageService? usageService,
    Map<String, String>? hostEnvironment,
    DataService? data,
  }) : _lanPort = lanPort,
       _lanAddress = lanAddress,
       _own = config,
       _localRelayEnabled = localRelayEnabled,
       _localRelayPort = localRelayPort,
       _lanInterfaces = lanInterfaces ?? lanInterfaceAddresses,
       _relayFactory = relayFactory,
       _pushPost = pushPost,
       _now = clock ?? DateTime.now,
       _newId = newId ?? newUuid,
       _dataService = data ?? DataService(database, newId: newId),
       _devices = PairedDeviceDao(database),
       _sessions = SessionDao(database),
       _rows = CheckoutRows(database),
       _hostEnvironment = hostEnvironment ?? Platform.environment,
       screens = screens ?? RegistryScreens(registry) {
    _facts = DaemonCheckoutFacts(_rows, windows: windows);
    _stores = CliStoreLocator(
      runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
        _rows.environment(id) ?? localHostEnvironment(_now()),
      ),
      installations: WorkspaceRows(database).installations(),
      environment: _hostEnvironment,
    );
    _usage =
        usageService ??
        AgentUsageService(storeLocator: _stores, clock: const SystemClock());
    // A client's rename, grant or revoke reaches the phones' live links.
    _dataService.onDevicesWritten = () {
      final service = _service;
      if (service != null) unawaited(service.reconcileDevices());
    };
    // "Move to the default relay": the hosted relay new pairings get.
    _dataService.defaultRelay = () => hostedRelay;
    this.localRelay =
        localRelay ??
        ServerLocalRelay(
          // netsh exists only on Windows; elsewhere the OS prompt is the story.
          firewall: Platform.isWindows ? const LocalCommandRunner() : null,
          onLog: onLog,
        );
    final directory = dataDirectory;
    attachments = directory == null
        ? null
        : CompanionAttachmentStore(Directory(p.join(directory, 'attachments')));
  }

  /// Serves a desktop client whose sealed channel switched to the host
  /// protocol (slice 5e); set by `serve` once its host server exists.
  void Function(SealedHostLink link)? onHostLink;

  final AppDatabase database;
  final SessionRegistry registry;
  final String hostName;

  /// Where the LAN listener binds first; another port when it is taken, which
  /// the beacon and `host.status` carry.
  int get lanPort => _lanPort;
  int _lanPort;

  /// The address the LAN listener binds (`server.json`'s `companion.bind`).
  String get lanAddress => _lanAddress;
  String _lanAddress;

  /// How the server's config says to serve; [config] adds where the local
  /// relay can be dialled while it runs.
  CompanionConfig get ownConfig => _own;
  CompanionConfig _own;

  /// The LAN relay this server hosts while `companion.localRelay` is on and
  /// phones are served.
  late final ServerLocalRelay localRelay;

  /// Whether the config asks for [localRelay], and on which port.
  bool get localRelayEnabled => _localRelayEnabled;
  bool _localRelayEnabled;
  int _localRelayPort;

  final LanInterfaceLister _lanInterfaces;

  /// What the server's attention says of a session (slice 5c), set by
  /// `serve` once it is built: its agent's status, what it asks of a person,
  /// and a usage limit's words while unseen. Until then a phone's list reads
  /// the prompts' own status.
  AgentStatusReport? Function(String sessionId)? statusOf;
  String? Function(String sessionId)? attentionOf;
  String? Function(String sessionId)? usageLimitOf;

  /// Sends a phone's message to a session whose agent the server speaks to
  /// over a protocol — resuming it when nothing runs it — set by `serve`:
  /// true once sent or queued behind a running turn, false for a session
  /// typed into instead. Throws [StateError] in words when it is refused.
  Future<bool> Function(String sessionId, String text)? sendOverProtocol;

  /// Every agent record on this machine, `agentId/conversationId` → path
  /// (the conversation index's walk), set by `serve`: a phone's
  /// transcript is read from the agent's own record through it. Unset, every
  /// transcript is the screen's.
  Future<Map<String, String>> Function()? recordIndex;

  /// The server's own delivery reading of a session (`DeliveryWatch`), as a
  /// stage name; unset or unread, "could not tell".
  String? Function(String sessionId)? deliveryStageOf;

  final AgentRecords _records = AgentRecords();

  /// Where [sessionId]'s agent keeps its record here: imported history names
  /// its file; a row names its agent and conversation, found in the index.
  Future<AgentRecordLocation?> _recordOf(String sessionId) async {
    final index = recordIndex;
    final found = await lookUpSessionRecord(
      sessionId,
      imported: ImportedSessionDao(database),
      sessions: _sessions,
      installation: _rows.installation,
      locate: (agentId, conversation) async =>
          index == null ? null : (await index())['$agentId/$conversation'],
    );
    final path = found.path;
    final agentId = found.agentId;
    return path == null || agentId == null
        ? null
        : (path: path, agentId: agentId);
  }

  /// [sendOverProtocol], its refusal in the companion API's terms.
  Future<bool> _sendOverProtocol(String sessionId, String text) async {
    final send = sendOverProtocol;
    if (send == null) return false;
    try {
      return await send(sessionId, text);
    } on StateError catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, error.message);
    }
  }

  final Duration transcriptPollInterval;
  final CompanionScreens screens;

  /// Answers approvals, questions and menus for the sessions this host holds,
  /// app or no app; null when no agent status is kept (no store).
  final DaemonPromptAnswers? prompts;

  /// Lifecycle only — never a code, a key or a payload.
  final void Function(String message)? onLog;

  /// The app's data directory — the store's — under which a file a phone
  /// sends is kept (`attachments/`). Null keeps none.
  final String? dataDirectory;

  final RelayTransportFactory? _relayFactory;
  final PushPost? _pushPost;
  final DateTime Function() _now;
  final String Function() _newId;

  /// This companion's own link to the server's data API: a project a phone
  /// adds is written there, so every client is told.
  final DataService _dataService;
  late final DataSession _data = _dataService.open((_) {});
  final PairedDeviceDao _devices;
  final SessionDao _sessions;
  final CheckoutRows _rows;
  final Map<String, String> _hostEnvironment;
  late final DaemonCheckoutFacts _facts;
  late final CliStoreLocator _stores;
  late final AgentUsageService _usage;

  /// Where a file a phone sends is kept while no app is connected.
  late final CompanionAttachmentStore? attachments;

  /// Starting, resuming and reconfiguring sessions for a phone with no app,
  /// once [serveSessions] has what a launch needs.
  DaemonSessionControl? _control;
  late final _ControlSlot _controlSlot = _ControlSlot(() => _control);

  late final RemoteHostBindings bindings = hostCompanionBindings(
    hostName: hostName,
    hosted: prompts == null ? null : CompanionPrompts(prompts!.answering),
    holds: prompts?.holds,
    workspace: HostedWorkspace(
      rows: WorkspaceRows(database),
      isHere: _facts.isHere,
      createProject: _createProject,
    ),
    control: _controlSlot,
    usage: _usageSnapshot,
    attachments: attachments,
    deliveryStageOf: (sessionId) => deliveryStageOf?.call(sessionId),
    atRest: SessionsAtRest(
      sessions: _sessions,
      names: WorkspaceNames(database),
      screens: screens,
      hostName: hostName,
      agentStatusOf: (sessionId) =>
          statusOf?.call(sessionId) ?? prompts?.statusOf(sessionId),
      attentionOf: (sessionId) => attentionOf == null
          ? remoteAttentionOf(prompts?.statusOf(sessionId))
          : attentionOf!(sessionId),
      usageLimitOf: (sessionId) => usageLimitOf?.call(sessionId),
      agentIdOf: (installationId) =>
          _rows.installation(installationId)?.agentId,
      imported: ImportedSessionDao(database).getAll,
      recordOf: _recordOf,
      records: _records,
      attachments: attachments,
      attachmentSupportOf: attachments == null ? null : _attachmentSupport,
      deliverOverProtocol: _sendOverProtocol,
      clock: _now,
    ),
    notes: () async => notesSnapshot(
      notes: NoteDao(database).list(),
      todos: TodoDao(database).list(),
      projectNames: WorkspaceNames(database).projects(),
      notesEnabled: _config.notesEnabled,
    ),
    registerPush: (deviceId, token, platform, presence) async {
      _devices.updatePush(
        deviceId,
        token: token,
        platform: platform,
        presence: presence,
        now: _now().toUtc(),
      );
      _devicesChanged();
    },
  );

  CompanionConfig _config = CompanionConfig.off;
  RemoteHostService? _service;
  Future<void> _chain = Future<void>.value();
  StreamSubscription<LifecycleEvent>? _events;

  /// The running server, or null while remote access is off.
  RemoteHostService? get service => _service;

  /// What it is serving by now.
  CompanionConfig get config => _config;

  /// The hosted relay this server pairs through — the default or the owner's
  /// own — or null when hosted pairing is off. Webhooks listen on it too.
  Uri? get hostedRelay => _config.hostedEnabled
      ? _service?.relay ?? KnownRelays.popupBits.upgrade(_config.relay)
      : null;

  /// Where the LAN listener bound, while serving.
  int? get port => _service?.lanPortBound;

  int paired() => _devices.getActive().length;

  /// From now on a phone can start and resume sessions on this machine, and
  /// change the model or mode one runs under, with no app connected: each
  /// agent launched as the host's own session, reaching Karmashala's tools
  /// through [mcp]. Called once the MCP endpoint is up; until then those
  /// calls say the app is not running. [openAgent] starts each agent as one
  /// of the server's terminals, so `terminal_list` shows it; null opens it in
  /// the registry alone.
  void serveSessions({
    required SessionMcpAccessPoint mcp,
    AgentTerminalOpener? openAgent,
  }) {
    final facts = _facts;
    final launcher = HostedAgentLauncher(
      registry: registry,
      sessions: _sessions,
      onRowWritten: _announceSession,
      mcp: mcp,
      openAgent: openAgent,
      now: () => _now().toUtc(),
      newId: _newId,
      environmentOf: _rows.environment,
      hostEnvironment: _hostEnvironment,
      worktrees: daemonWorktrees(
        database: database,
        registry: registry,
        facts: facts,
        newId: _newId,
        record: _dataService.recordWorktreeSetup,
      ),
    );
    this.launcher = launcher;
    _control = DaemonSessionControl(
      rows: _rows,
      facts: facts,
      sessions: _sessions,
      registry: registry,
      screens: screens,
      presenceOf: _presenceOf,
      statusOf: prompts?.statusOf,
      press: prompts?.press,
      screenOf: prompts?.screen,
      onRowWritten: _announceSession,
      launcher: launcher,
    );
  }

  /// How this server starts an agent session in its own environment — a
  /// phone's start, and an agent's `open_new_session` while no app is open.
  /// Null until [serveSessions].
  HostedAgentLauncher? launcher;

  /// A row this companion wrote, told to every client on the data channel.
  void _announceSession(String sessionId) =>
      _dataService.announceSessions([sessionId]);

  ({Project project, List<Repository> checkouts}) _createProject(
    String name,
    EnvironmentPath root,
    List<DiscoveredRepository> found,
  ) {
    try {
      final created = _data
          .handle(ProjectCreate(projectName: name, root: root, found: found))
          .value;
      return (project: created.project, checkouts: created.repositories);
    } on DataRefused catch (refusal) {
      throw RemoteApiRefusal(
        refusal.code == DataRefusalCode.notFound
            ? ErrorCode.notFound
            : ErrorCode.badRequest,
        refusal.message,
      );
    }
  }

  /// Every agent account's usage on this machine, through each adapter's
  /// usage capability — the snapshot the app builds, from this host's reads.
  Future<RemoteUsageSnapshot> _usageSnapshot() {
    final workspace = WorkspaceRows(database);
    final environments = workspace.environments();
    final here = {
      for (final environment in environments)
        if (_facts.isHere(environment)) environment.id,
    };
    return companionUsageSnapshot(
      // Only what this host can read: its own machine's agents.
      installations: [
        for (final installation in workspace.installations())
          if (here.contains(installation.environmentId)) installation,
      ],
      registry: AgentRegistry.builtIn,
      service: _usage,
      environments: environments,
      history: _usageSamples,
      environmentName: (id) {
        for (final environment in environments) {
          if (environment.id == id) {
            return environmentLabel(environment) ?? environment.name;
          }
        }
        return id;
      },
      now: _now().toUtc(),
    );
  }

  /// The readings the app recorded for [accountKey] since [since], oldest
  /// first. Read only: the history is the app's to keep and prune.
  List<UsageSample> _usageSamples(String accountKey, DateTime since) {
    try {
      return [
        for (final row in database.query(
          'SELECT * FROM usage_samples WHERE account_key = ? '
          'AND recorded_at >= ? ORDER BY recorded_at ASC;',
          [accountKey, isoFromDate(since)],
        ))
          UsageSample(
            accountKey: row['account_key']! as String,
            windowLabel: row['window_label']! as String,
            percent: (row['percent']! as num).toDouble(),
            recordedAt: dateFromIso(row['recorded_at']),
          ),
      ];
    } on Object {
      return const [];
    }
  }

  /// What a file sent to [row]'s session may be: its agent's declared support,
  /// on this machine only — a path written here is nothing to an agent
  /// elsewhere.
  RemoteAttachmentSupport _attachmentSupport(Session row) {
    final installation = _rows.installation(row.agentInstallationId);
    final support = agentAttachmentSupport(
      installation == null
          ? null
          : AgentRegistry.builtIn.byId(installation.agentId),
    );
    if (support.refusal != null || installation == null) return support;
    if (!_facts.isHostLocal(installation.executable)) {
      return RemoteAttachmentSupport.refused(
        '${_facts.describeEnvironment(installation.executable)} runs '
        'elsewhere — a file written here is not a file it can open.',
      );
    }
    return support;
  }

  /// Whether [agentId]'s own store on this machine holds [conversationId],
  /// through its adapter's store capability.
  Future<ConversationPresence> _presenceOf(
    String agentId,
    String conversationId,
  ) async {
    final store = AgentRegistry.builtIn.adapterFor(agentId)?.store;
    if (store == null) return ConversationPresence.unknown;
    final here = [
      for (final environment in WorkspaceRows(database).environments())
        if (_facts.isHere(environment)) environment,
    ];
    try {
      var answer = ConversationPresence.unknown;
      for (final located in await _stores.locate(here)) {
        final home = located.homeFor(agentId);
        if (home == null) continue;
        final found = await const ConversationStoreIndex().presenceOf(
          storeHome: home,
          store: store,
          conversationId: conversationId,
        );
        if (found == ConversationPresence.present) return found;
        if (found == ConversationPresence.absent) answer = found;
      }
      return answer;
    } on Object {
      return ConversationPresence.unknown;
    }
  }

  /// Serves by the server's config, following [sessionEvents] — the host's
  /// lifecycle feed. What the agents are doing reaches phones through the
  /// server's attention ([sessionsMoved], [approvalRequested],
  /// [attentionFiled]). Throws when the LAN listener cannot bind at all.
  Future<void> start({required Stream<LifecycleEvent> sessionEvents}) async {
    // The one moment provably no upload is in flight.
    await attachments?.sweep();
    _events = sessionEvents.listen(_onLifecycle);
    await _serialised(_bringInLine);
  }

  /// Serves by [config] from now on, bound to [lanAddress] on [lanPort], its
  /// LAN relay on [localRelayPort] while [localRelayEnabled]: the server's
  /// config changed (`server.config.set`). The listener restarts only when
  /// what it was started with moved; relays are re-pointed in place.
  Future<void> reconfigure({
    required CompanionConfig config,
    required String lanAddress,
    required int lanPort,
    bool localRelayEnabled = false,
    int localRelayPort = kDefaultLocalRelayPort,
  }) => _serialised(() async {
    final moved = lanAddress != _lanAddress || lanPort != _lanPort;
    _own = config;
    _lanAddress = lanAddress;
    _lanPort = lanPort;
    _localRelayEnabled = localRelayEnabled;
    _localRelayPort = localRelayPort;
    if (moved) await _stopService();
    await _bringInLine();
  });

  /// The local relay brought to what the config asks, then the phone
  /// listener served by the config plus where that relay can be dialled.
  Future<void> _bringInLine() async {
    if (_own.enabled && _localRelayEnabled) {
      await localRelay.ensureRunning(
        port: _localRelayPort,
        address: _lanAddress,
      );
    } else {
      await localRelay.stop();
    }
    final status = localRelay.status;
    await _apply(
      _own.withLocalRelay(status.running ? status.primaryUrl : null),
    );
  }

  /// What the local relay is doing now — for `server.config.get`, the
  /// desktop's settings row and the greeting.
  LocalRelayStatus get localRelayStatus => localRelay.status;

  @override
  Future<CompanionPairingWindow> openPairing({
    required int capabilities,
    required String relay,
    required bool relayIsLocal,
    String label = '',
  }) async {
    final service = _service;
    if (service == null || !service.isRunning) {
      throw StateError('remote access is switched off on this machine');
    }
    final named = relay.trim();
    final Uri? via;
    if (relayIsLocal) {
      // This server's own LAN relay, wherever it listens now: the pairing is
      // met there and the row remembers only that it was the local one.
      via = localRelay.status.running ? localRelay.status.primaryUrl : null;
      if (via == null) {
        throw StateError(
          'the local relay is not running on this machine'
          '${localRelay.status.error == null ? '' : ' (${localRelay.status.error})'}',
        );
      }
    } else {
      via = named.isEmpty ? null : _usableRelay(named);
      if (named.isNotEmpty && via == null) {
        throw FormatException('"$relay" is not a relay this host can dial');
      }
    }
    final session = await service.beginPairing(
      capabilities: CapabilitySet(capabilities),
      relay: via,
      relayIsLocal: relayIsLocal,
    );
    final name = label.trim();
    return (
      code: PairingCode.encode(session.payload.typedSecret!),
      expiresAt: session.deadline,
      payload: session.payload.encode(),
      paired: session.done.then((device) {
        // The name the person gave the window, over the one the phone sent:
        // `pair --name` is how a server's owner tells two phones apart.
        if (name.isNotEmpty) {
          _devices.rename(device.id, name);
          _devicesChanged();
        }
        return device.id;
      }),
    );
  }

  /// Every pairing on record, revoked ones included, oldest first.
  List<PairedDevice> devices() => _devices.getAll();

  /// Revokes [deviceId] and drops its live links; the device row stays, marked
  /// revoked, as the app's own revoke leaves it. Throws [StateError] when no
  /// such device is paired.
  Future<PairedDevice> revokeDevice(String deviceId) async {
    final device = _devices.getById(deviceId);
    if (device == null) {
      throw StateError('no paired device has the id "$deviceId"');
    }
    _devices.revoke(deviceId);
    await _service?.reconcileDevices();
    _devicesChanged();
    return device;
  }

  @override
  Future<void> notice(Object owner, CompanionNoticeMessage notice) async {
    final service = _service;
    if (service == null) return;
    switch (notice.kind) {
      case CompanionNoticeKind.pairingCancelled:
        await service.cancelPairing();
    }
  }

  Future<void> close() async {
    await _events?.cancel();
    _events = null;
    await _serialised(() async {
      await _stopService();
      await localRelay.stop();
    });
  }

  /// Something a phone's list shows moved — a status, who is waiting: live
  /// phones read their subscriptions again.
  void sessionsMoved() => _sessionsMoved();

  /// Row [sessionId]'s agent started waiting on a person: news for every
  /// live phone, which the phone turns into its approval card.
  void approvalRequested(String sessionId) {
    final service = _service;
    if (service == null) return;
    unawaited(
      service
          .notifyApprovalRequested(sessionId)
          .catchError(
            (Object error) => onLog?.call('approval news failed: $error'),
          ),
    );
  }

  /// Items new to the server's inbox: sealed pushes for paired phones with no
  /// live link (a connected phone hears it as `session.changed`). Delivery
  /// news and follow-ups stay on the desktop: what a session left behind is
  /// to sit down with, not a buzz in a pocket.
  void attentionFiled(List<InboxItem> items) {
    final service = _service;
    if (service == null) return;
    var limitFiled = false;
    for (final item in items) {
      if (item.session.imported) continue;
      final kind = switch (item.kind) {
        InboxItemKind.finished => 'finished',
        InboxItemKind.needsApproval => kAttentionNeedsApproval,
        InboxItemKind.failed => 'failed',
        InboxItemKind.usageLimit => kAttentionUsageLimit,
        InboxItemKind.checksFailed ||
        InboxItemKind.changesRequested ||
        InboxItemKind.readyToMerge ||
        InboxItemKind.followUp ||
        InboxItemKind.turnCutOff ||
        InboxItemKind.automationProposed ||
        InboxItemKind.wentQuiet ||
        // A phone hears these live, as `storeChangesNoticed`.
        InboxItemKind.storeAttention ||
        InboxItemKind.storeNews ||
        InboxItemKind.waitingForSlot ||
        InboxItemKind.pipelineWaiting ||
        InboxItemKind.pipelineFailed => null,
      };
      if (kind == null) continue;
      if (item.kind == InboxItemKind.usageLimit) limitFiled = true;
      unawaited(
        service
            .pushAttentionNews(
              sessionId: item.session.openId,
              title: item.session.label,
              kind: kind,
              // "Codex hit its 5-hour limit. Resets 14:05." — the reset is
              // the news.
              detail: item.kind == InboxItemKind.usageLimit
                  ? item.detail
                  : null,
            )
            .catchError(
              (Object error) => onLog?.call('attention push failed: $error'),
            ),
      );
    }
    // A limit is carried on the session's snapshot, which nothing else moves
    // when it is filed; a connected phone hears it from this.
    if (limitFiled) _sessionsMoved();
  }

  Future<void> _serialised(Future<void> Function() step) {
    final next = _chain.then((_) => step());
    _chain = next.catchError((Object error) {
      onLog?.call('the companion could not be brought in line: $error');
    });
    return next;
  }

  Future<void> _apply(CompanionConfig next) async {
    final previous = _config;
    _config = next;
    if (!next.enabled) {
      await _stopService();
      return;
    }
    final running = _service;
    if (running != null && !previous.restartsFor(next)) {
      await running.updateRelays(
        localRelayUrl: next.localRelayUrl,
        hostedEnabled: next.hostedEnabled,
        extraRelays: next.extraRelays,
      );
      return;
    }
    await _stopService();
    final started = RemoteHostService(
      devices: _devices,
      hostId: hostDeviceIdFor(database),
      bindings: bindings,
      relay: next.relay,
      localRelayUrl: next.localRelayUrl,
      hostedEnabled: next.hostedEnabled,
      extraRelays: next.extraRelays,
      lanPort: _lanPort,
      lanAddress: _lanAddress,
      lanHost: await _lanHost(),
      advertise: next.advertise,
      transcriptPollInterval: transcriptPollInterval,
      now: _now,
      relayFactory: _relayFactory,
      pushPost: _pushPost,
      onDevicesChanged: _devicesChanged,
      onHostLink: (link) => onHostLink?.call(link),
      onLog: onLog,
    );
    _service = started;
    await started.start();
  }

  /// The address a phone on this network dials the LAN listener at, for the
  /// hint `host.status` carries: the bound address when it names one, else
  /// this machine's likeliest LAN address. Null on loopback.
  Future<String?> _lanHost() async {
    final bound = InternetAddress.tryParse(_lanAddress);
    if (bound == null || bound.isLoopback) return null;
    if (bound != InternetAddress.anyIPv4 && bound != InternetAddress.anyIPv6) {
      return bound.address;
    }
    try {
      final addresses = await _lanInterfaces();
      if (addresses.isEmpty) return null;
      final ranked = [...addresses]
        ..sort((a, b) => lanAddressScore(a).compareTo(lanAddressScore(b)));
      return ranked.first.ip;
    } on Object {
      return null;
    }
  }

  Future<void> _stopService() async {
    final service = _service;
    _service = null;
    await service?.stop();
  }

  /// Rows this companion wrote itself, told to every client without secrets.
  void _devicesChanged() => _dataService.announceDevices();

  void _sessionsMoved() {
    final service = _service;
    if (service != null) unawaited(service.notifySessionsChanged());
  }

  /// A session this host runs started or ended: live phones re-read. What it
  /// means for a person — a finished turn, a failure — is the attention's to
  /// file and push ([attentionFiled]).
  void _onLifecycle(LifecycleEvent event) {
    // After the status recording, which listens on the same synchronous feed
    // and writes the row this change is read from.
    scheduleMicrotask(_sessionsMoved);
  }

  /// The relay a pairing names, or null when it names none this host can
  /// dial. [kLocalRelayMarker] is a word for the local relay, not a URL.
  static Uri? _usableRelay(String url) {
    if (url == kLocalRelayMarker) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty) return null;
    return switch (parsed.scheme) {
      'ws' || 'wss' || 'http' || 'https' => parsed,
      _ => null,
    };
  }
}

/// The sessions a phone starts, resumes and reconfigures, held for the
/// bindings before [DaemonCompanion.serveSessions] has what a launch needs:
/// until then each call says the server cannot do it yet.
class _ControlSlot implements HostedSessionControl {
  _ControlSlot(this._control);

  final DaemonSessionControl? Function() _control;

  HostedSessionControl get _here {
    final control = _control();
    if (control == null) throw companionNotServedHere;
    return control;
  }

  @override
  Future<RemoteSessionStarted> start(RemoteSessionStartRequest request) =>
      Future.sync(() => _here.start(request));

  @override
  Future<RemoteSessionStarted> resume(String sessionId) =>
      Future.sync(() => _here.resume(sessionId));

  @override
  Future<RemoteSessionOptions> options(String sessionId) =>
      Future.sync(() => _here.options(sessionId));

  @override
  Future<RemoteConfigureOutcome> configure(
    String sessionId, {
    ({String? id})? model,
    ({String? id})? permission,
  }) => Future.sync(
    () => _here.configure(sessionId, model: model, permission: permission),
  );
}
