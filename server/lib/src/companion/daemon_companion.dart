import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentRegistry;
import 'package:agent_cli/discovery.dart' show SystemClock;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart'
    show CliStoreLocator, ConversationPresence, ConversationStoreIndex;
import 'package:agent_cli/usage.dart' show AgentUsageService, UsageSample;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_automations/persistence.dart' show CheckoutRows;
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart' show Session;
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:path/path.dart' as p;

import '../automations/daemon_checkout_facts.dart';
import '../automations/hosted_agent_launcher.dart';
import '../automations/session_mcp_access.dart';
import '../domain/session_registry.dart';
import '../domain/uuid.dart';
import '../protocol/messages.dart';
import '../status/daemon_prompt_answers.dart';
import 'companion_app_relay.dart';
import 'companion_handler.dart';
import 'daemon_session_control.dart';
import 'daemon_worktrees.dart';
import 'registry_screens.dart';

/// The phone companion, served by the daemon: the one companion server on a
/// machine with a session host, running whether or not the desktop app is.
///
/// It runs `RemoteHostService` — pairing, sealed channels, the LAN listener and
/// beacon, relay listeners, push — on the shared store's paired devices, with
/// the bindings `hostCompanionBindings` composes: the store and this host's own
/// screens while no app is connected, and calls forwarded to the app while one
/// is. How it serves is the server's own config (`server.json`, [config]),
/// which the desktop's Remote access settings write through
/// `server.config.set` and [reconfigure] applies at once; the only thing an
/// app adds is where its embedded relay listens, while it is connected.
class DaemonCompanion implements CompanionHandler {
  DaemonCompanion({
    required this.database,
    required this.registry,
    required this.hostName,
    this.dataDirectory,
    int lanPort = kHostCompanionPort,
    String lanAddress = '127.0.0.1',
    CompanionConfig config = CompanionConfig.off,
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
  }) : _lanPort = lanPort,
       _lanAddress = lanAddress,
       _own = config,
       _relayFactory = relayFactory,
       _pushPost = pushPost,
       _now = clock ?? DateTime.now,
       _newId = newId ?? newUuid,
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
    final directory = dataDirectory;
    attachments = directory == null
        ? null
        : CompanionAttachmentStore(Directory(p.join(directory, 'attachments')));
  }

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

  /// How the server's config says to serve, without the app's embedded relay.
  CompanionConfig get ownConfig => _own;
  CompanionConfig _own;

  /// Where the connected app's embedded relay listens, or null — none, or no
  /// app. Never kept: it closes with the app.
  Uri? _localRelay;
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

  /// The desktop app companion calls are forwarded to, while one is connected.
  final CompanionAppRelay app = CompanionAppRelay();

  late final RemoteHostBindings bindings = hostCompanionBindings(
    hostName: hostName,
    app: app,
    hosted: prompts == null ? null : CompanionPrompts(prompts!.answers),
    holds: prompts?.holds,
    workspace: HostedWorkspace(
      rows: WorkspaceRows(database),
      isHere: _facts.isHere,
      now: _now,
      newId: _newId,
    ),
    control: _controlSlot,
    usage: _usageSnapshot,
    attachments: attachments,
    atRest: SessionsAtRest(
      sessions: _sessions,
      names: WorkspaceNames(database),
      screens: screens,
      hostName: hostName,
      agentStatusOf: (sessionId) => prompts?.statusOf(sessionId),
      attachments: attachments,
      attachmentSupportOf: attachments == null ? null : _attachmentSupport,
      clock: _now,
    ),
    notes: () async => notesSnapshot(
      notes: NoteDao(database),
      todos: TodoDao(database),
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
  void Function(HostMessage)? _appSend;
  Future<void> _chain = Future<void>.value();
  StreamSubscription<LifecycleEvent>? _events;
  StreamSubscription<HostedAgentStatus>? _statuses;

  /// The running server, or null while remote access is off.
  RemoteHostService? get service => _service;

  /// What it is serving by now.
  CompanionConfig get config => _config;

  /// Where the LAN listener bound, while serving.
  int? get port => _service?.lanPortBound;

  int paired() => _devices.getActive().length;

  /// From now on a phone can start and resume sessions on this machine, and
  /// change the model or mode one runs under, with no app connected: each
  /// agent launched as the host's own session, reaching Karmashala's tools
  /// through [mcp]. Called once the MCP endpoint is up; until then those
  /// calls say the app is not running.
  void serveSessions({required SessionMcpAccessPoint mcp}) {
    final facts = _facts;
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
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: _sessions,
        mcp: mcp,
        now: () => _now().toUtc(),
        newId: _newId,
        hostEnvironment: _hostEnvironment,
        worktrees: daemonWorktrees(
          database: database,
          registry: registry,
          facts: facts,
          newId: _newId,
        ),
      ),
    );
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
  /// lifecycle feed — and [statusChanges], what the agents it holds are
  /// doing. Throws when the LAN listener cannot bind at all.
  Future<void> start({
    required Stream<LifecycleEvent> sessionEvents,
    Stream<HostedAgentStatus>? statusChanges,
  }) async {
    app.onChanged = (_) => _sessionsMoved();
    // The one moment provably no upload is in flight.
    await attachments?.sweep();
    _events = sessionEvents.listen(_onLifecycle);
    _statuses = statusChanges?.listen(_onStatus);
    await _serialised(() => _apply(_served()));
  }

  /// Serves by [config] from now on, bound to [lanAddress] on [lanPort]: the
  /// server's config changed (`server.config.set`). The listener restarts
  /// only when what it was started with moved; relays are re-pointed in
  /// place.
  Future<void> reconfigure({
    required CompanionConfig config,
    required String lanAddress,
    required int lanPort,
  }) => _serialised(() async {
    final moved = lanAddress != _lanAddress || lanPort != _lanPort;
    _own = config;
    _lanAddress = lanAddress;
    _lanPort = lanPort;
    if (moved) await _stopService();
    await _apply(_served());
  });

  /// The server's config, with the connected app's embedded relay.
  CompanionConfig _served() => _own.withLocalRelay(_localRelay);

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
    final via = named.isEmpty ? null : _usableRelay(named);
    if (named.isNotEmpty && via == null) {
      throw FormatException('"$relay" is not a relay this host can dial');
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
  Future<void> adopt(
    Object owner,
    Uri? localRelay,
    void Function(HostMessage) send,
  ) {
    _appSend = send;
    app.adopt(owner, send);
    return _serialised(() {
      _localRelay = localRelay;
      return _apply(_served());
    });
  }

  @override
  void answer(Object owner, CompanionResultMessage result) =>
      app.answer(owner, result);

  @override
  Future<void> notice(Object owner, CompanionNoticeMessage notice) async {
    final service = _service;
    if (service == null) return;
    // The two fan-outs that ask the app — its session list, its approval
    // evidence — are not awaited: the app answers on the very link this
    // notice came in on, whose next frame is read only once this returns.
    switch (notice.kind) {
      case CompanionNoticeKind.sessionsMoved:
        _sessionsMoved();
      case CompanionNoticeKind.approvalRequested:
        final sessionId = notice.sessionId;
        if (sessionId == null) return;
        unawaited(
          service
              .notifyApprovalRequested(sessionId)
              .catchError(
                (Object error) => onLog?.call('approval news failed: $error'),
              ),
        );
      case CompanionNoticeKind.attention:
        final sessionId = notice.sessionId;
        final kind = notice.attention;
        if (sessionId == null || kind == null) return;
        await service.pushAttentionNews(
          sessionId: sessionId,
          title: notice.title ?? '',
          kind: kind,
          detail: notice.detail,
        );
      case CompanionNoticeKind.devicesChanged:
        await service.reconcileDevices();
      case CompanionNoticeKind.pairingCancelled:
        await service.cancelPairing();
    }
  }

  @override
  Future<void> detach(Object owner) async {
    final wasApp = app.isApp(owner);
    app.detach(owner);
    if (!wasApp) return;
    _appSend = null;
    // The app's embedded relay closed with it; nothing waits there any more.
    await _serialised(() {
      _localRelay = null;
      return _apply(_served());
    });
  }

  Future<void> close() async {
    await _events?.cancel();
    _events = null;
    await _statuses?.cancel();
    _statuses = null;
    app.onChanged = null;
    app.close();
    await _serialised(_stopService);
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
      advertise: next.advertise,
      transcriptPollInterval: transcriptPollInterval,
      now: _now,
      relayFactory: _relayFactory,
      pushPost: _pushPost,
      onDevicesChanged: _devicesChanged,
      onLog: onLog,
    );
    _service = started;
    await started.start();
  }

  Future<void> _stopService() async {
    final service = _service;
    _service = null;
    await service?.stop();
  }

  void _devicesChanged() => _appSend?.call(
    const CompanionEventMessage(CompanionEventKind.devicesChanged),
  );

  void _sessionsMoved() {
    final service = _service;
    if (service != null) unawaited(service.notifySessionsChanged());
  }

  /// A session this host runs started or ended: live phones re-read, and —
  /// with no app to file an inbox item — a phone with no live link is pushed
  /// the ending, as the app's inbox would have.
  void _onLifecycle(LifecycleEvent event) {
    // After the status recording, which listens on the same synchronous feed
    // and writes the row this change is read from.
    scheduleMicrotask(() {
      _sessionsMoved();
      if (event.kind == LifecycleEventKind.exited && !app.connected) {
        unawaited(_pushEnding(event));
      }
    });
  }

  /// An agent this host holds moved: live phones re-read their lists, and —
  /// with no app to announce it — a prompt opening is news, as the app's
  /// `approvalRequested` notice would have made it.
  void _onStatus(HostedAgentStatus status) {
    final wasWaiting = _waiting.contains(status.sessionId);
    final waiting =
        status.report.status == AgentActivityStatus.awaitingApproval;
    if (waiting) {
      _waiting.add(status.sessionId);
    } else {
      _waiting.remove(status.sessionId);
    }
    if (app.connected) return;
    _sessionsMoved();
    final service = _service;
    if (service == null || !waiting || wasWaiting) return;
    unawaited(
      service
          .notifyApprovalRequested(status.sessionId)
          .catchError(
            (Object error) => onLog?.call('approval news failed: $error'),
          ),
    );
  }

  /// Rows whose agent is waiting on a person now, so each wait is news once.
  final _waiting = <String>{};

  Future<void> _pushEnding(LifecycleEvent event) async {
    final service = _service;
    final code = event.exitCode;
    // Ended by request, or with no code to judge by: nothing to announce.
    if (service == null || event.endedByClose || code == null) return;
    final rows = _sessions.getAll();
    final rowId = sessionIdForHostId(event.sessionId, [
      for (final row in rows) row.id,
    ]);
    final row = rowId == null
        ? null
        : rows.firstWhere((candidate) => candidate.id == rowId);
    await service.pushAttentionNews(
      sessionId: rowId ?? event.sessionId,
      title:
          row?.title ??
          screens.find(event.sessionId)?.command ??
          event.sessionId,
      kind: code == 0 ? 'finished' : 'failed',
    );
  }

  /// The relay a pairing names, or null when it names none this host can
  /// dial. [kLocalRelayMarker] is a word for the app's own relay, not a URL.
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
/// until then each call says the app is not running, as with no host control.
class _ControlSlot implements HostedSessionControl {
  _ControlSlot(this._control);

  final DaemonSessionControl? Function() _control;

  HostedSessionControl get _here {
    final control = _control();
    if (control == null) throw companionAppNotRunning;
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
