part of '../serve_command.dart';

/// The loopback hook listener, on the last run's port and token when that port
/// is still free, with [HostPaths.hookEndpointPath] written for the app. Null,
/// reported, when either fails: sessions do not need hooks.
/// The spools of the WSL agents this server's store records: each
/// distribution's stores located as the conversation index locates them,
/// read afresh each time (a distribution added later is drained too).
Future<List<HookSpoolSource>> Function() _wslSpoolSources(
  AppDatabase database,
) {
  final environments = ExecutionEnvironmentDao(database);
  return () async {
    final all = environments.getAll();
    if (!all.any((e) => e.kind == EnvironmentKind.wsl)) return const [];
    final locator = CliStoreLocator(
      runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
        environments.getById(id) ??
            localHostEnvironment(DateTime.now().toUtc()),
      ),
    );
    return wslHookSpoolSources(
      stores: await locator.locate(all),
      environments: all,
    );
  };
}

Future<HookServer?> _openHookServer(
  HostPaths paths,
  FutureOr<void> Function(AgentHookEvent hook) onHook,
  IOSink errSink,
) async {
  final previous = HookEndpoint.read(paths.hookEndpointPath);
  HookServer? server;
  try {
    server = await HookServer.bind(
      onHook: onHook,
      port: previous?.port ?? 0,
      token: previous?.token,
    );
    await server.endpoint.write(paths.hookEndpointPath);
    return server;
  } on Object catch (error) {
    await server?.close();
    errSink.writeln('karmashala_host: no agent hook endpoint ($error)');
    return null;
  }
}

/// The MCP endpoint agents dial, with the handshake in [dataDirectory] where
/// the app and the bridge look. Null, reported, when it cannot start.
Future<DaemonMcp?> _openMcp(
  HostPaths paths,
  String dataDirectory,
  McpToolRelay relay,
  AppDatabase? database,
  int preferredPort,
  IOSink errSink,
) async {
  try {
    final sessions = database == null ? null : SessionDao(database);
    return await DaemonMcp.start(
      paths: paths,
      dataDirectory: dataDirectory,
      relay: relay,
      sessionIsOver: sessions == null
          ? null
          : (sessionId) => sessions.getById(sessionId)?.isOver ?? true,
      preferredPort: preferredPort,
      log: (message) => errSink.writeln('karmashala_host: $message'),
    );
  } on Object catch (error) {
    errSink.writeln('karmashala_host: no MCP endpoint ($error)');
    return null;
  }
}

/// The shared store at `<dataDirectory>/karmashala.sqlite`, or null, reported,
/// when this machine cannot hold one: sessions do not need a store, and a host
/// that refused to serve them for want of one would trade the larger thing for
/// the smaller. `karmashala_host probe-store` says which of four things failed.
AppDatabase? _openStore(String dataDirectory, IOSink errSink) {
  try {
    final directory = Directory(dataDirectory);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    // Refused when a newer build migrated it: this one would write tables
    // it does not know the shape of.
    return AppDatabase.open(directory, refuseNewerSchema: true);
  } on Object catch (error) {
    errSink.writeln(
      'karmashala_host: no store in $dataDirectory ($error) — run '
      '`probe-store` here',
    );
    return null;
  }
}

/// The scheduler, runs and checks, on the shared store. Null, reported, when
/// there is no store or they cannot start: sessions do not need automations.
Future<DaemonAutomations?> _startAutomations({
  required AppDatabase? database,
  required DataService data,
  required SessionStatusRecording? recording,
  required SessionRegistry registry,
  required HostServer server,
  required DaemonMcp? mcp,
  required McpToolRelay mcpTools,
  required String dataDirectory,
  required IOSink errSink,
  DaemonAgentStatus? agentStatus,
  CommandRunnerFactory? remote,
  ResumeUsage? usage,
  void Function(InboxItem item)? raise,
  void Function(UsageLimitNotice notice)? noticeUsageLimit,
  AgentTerminalOpener? openAgent,
  bool Function(ExecutionEnvironment environment)? reachesBox,
  AcpRuntimeFactory? acpRuntimes,
  WorktreeService? worktrees,
  Duration? githubSweepEvery,
  GithubClient? githubClient,
  CodeIdentityReader? identities,
  AcpStartAuth Function(AgentInstallation installation, AcpLaunchSpec spec)?
  acpAuth,
}) async {
  if (database == null || recording == null) return null;
  final automations = DaemonAutomations(
    database: database,
    remote: remote,
    registry: registry,
    dataDirectory: dataDirectory,
    mcp: SessionMcpAccessPoint(
      mcp: mcp,
      configDirectory: p.join(dataDirectory, 'mcp'),
    ),
    tell: data.announce,
    sessionWritten: (sessionId) => data.announceSessions([sessionId]),
    log: (message) => errSink.writeln('karmashala_host: $message'),
    // Scheduled resumes fire here (slice 5c): the agent's status, the
    // account's usage, and the decision filed where every client hears it.
    agentStatusOf: agentStatus?.statusOf,
    usage: usage,
    raise: raise,
    noticeUsageLimit: noticeUsageLimit,
    openAgent: openAgent,
    reachesBox: reachesBox,
    acpRuntimes: acpRuntimes,
    worktrees: worktrees,
    acpAuth: acpAuth,
    githubSweepEvery: githubSweepEvery,
    githubClient: githubClient,
    identities: identities,
    onDecision: (decision) => data.applyAsServer(
      DecisionAppend(
        DecisionRecord(
          sessionId: decision.sessionId,
          kind: DecisionKind.approvalGranted,
          summary: decision.summary,
          detail: decision.detail,
          decidedBy: decision.scheduledBy,
          origin: DecisionOrigin.scheduledResume,
          originId: decision.resumeId,
          recordedAt: DateTime.now().toUtc(),
        ),
      ),
    ),
  );
  data.automationsWritten = automations.written;
  try {
    await automations.start(
      recording.changes,
      agentStatus: agentStatus?.changes,
    );
    // A session's checks asked for by a client (`checks.run`).
    data.checksWork = automations;
    data.automationWork = automations;
    return automations;
  } on Object catch (error) {
    await automations.close();
    errSink.writeln('karmashala_host: automations did not start ($error)');
    return null;
  }
}

/// Webhooks: the calls the relay forwards, answered by starting automation
/// runs. Null, reported, without a store or automations to start them with.
Future<DaemonWebhooks?> _startWebhooks({
  required AppDatabase? database,
  required DataService data,
  required DaemonAutomations? automations,
  required Uri? Function() relay,
  required String dataDirectory,
  required IOSink errSink,
}) async {
  if (database == null || automations == null) return null;
  final webhooks = DaemonWebhooks(
    database: database,
    vault: ServerHookVault(dataDirectory: dataDirectory),
    launch: automations.startWebhookRun,
    busy: automations.checkoutBusy,
    relay: relay,
    tell: data.announce,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  final written = data.automationsWritten;
  data
    ..webhooksWork = webhooks
    ..automationsWritten = () {
      written?.call();
      webhooks.reconcile();
    };
  webhooks.reconcile();
  return webhooks;
}

/// What the greeting says of the LAN relay this server hosts.
String _localRelayLine(DaemonCompanion? companion) {
  if (companion == null || !companion.localRelayEnabled) {
    return 'local relay off (companion.localRelay in server.json)';
  }
  final status = companion.localRelayStatus;
  return switch (status.state) {
    LocalRelayState.running =>
      'local relay on ${status.primaryUrl ?? 'port ${status.boundPort}'}',
    LocalRelayState.error => 'local relay failed: ${status.error}',
    LocalRelayState.stopped => 'local relay stopped (phones are not served)',
  };
}

/// Starts serving phones. False, reported, when it cannot: sessions do not
/// need a companion.
Future<bool> _startCompanion(
  DaemonCompanion companion,
  LifecycleFeed lifecycle,
  IOSink errSink,
) async {
  try {
    await companion.start(sessionEvents: lifecycle.events);
    return true;
  } on Object catch (error) {
    errSink.writeln('karmashala_host: could not start the companion ($error)');
    return false;
  }
}

/// Creates [directory] if it is not there and makes it owner-only: the
/// server's store holds every phone's pairing key.
Future<void> _ensurePrivateDirectory(String directory) async {
  final dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final refused = await HostPaths(dir).restrictToCurrentUser();
  if (refused != null) throw FileSystemException(refused, directory);
}
