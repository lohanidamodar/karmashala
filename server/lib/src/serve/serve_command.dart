import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec;
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart'
    show
        CommandRunnerFactory,
        EnvironmentKind,
        ExecutionEnvironment,
        localHostEnvironment;
import 'package:agent_cli/read.dart' show CliStoreLocator;
import 'package:karmashala_environments/store.dart'
    show AcpAuthChoiceDao, ExecutionEnvironmentDao;

import 'package:karmashala_checkpoints/store.dart'
    show
        CheckpointDao,
        CheckpointScreenshotDao,
        sweepCheckpointScreenshotFolders;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        AnthropicSignIn,
        DataRefused,
        DecisionAppend,
        DecisionRecorded,
        OpenSessionTab,
        OpenTerminalTab,
        SessionAgentChanged,
        SessionQueueChanged,
        SessionSend,
        TerminalOpen,
        UsageLimitNotice,
        UsageLimitNoticed,
        kFlutterLogsStream;
import 'package:karmashala_flutter_apps/flutter_apps.dart'
    show FlutterAppException;
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_session_engine/store.dart'
    show
        DecisionRecordDao,
        SessionDelegationDao,
        ImportedSessionDao,
        SessionDao,
        SessionHandoffDao,
        SessionAgentSpanDao,
        SessionMessageDao,
        SessionQueueDao,
        SessionRepositoryDao,
        SessionUsageDao;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../acp/acp_auth.dart';
import '../acp/acp_runtimes.dart';
import '../acp/acp_titles.dart';
import '../acp/acp_transport.dart';
import '../acp/acp_session_modes.dart';
import '../acp/acp_version_probe.dart';
import '../agents/agent_folder_trust.dart';
import '../agents/agent_registry_holder.dart';
import '../agents/server_agent_work.dart';
import '../automations/hosted_agent_launcher.dart';
import '../automations/server_usage_limits.dart' show usageLimitQueueHold;
import '../mcp/tools/continuation_tool_set.dart';
import '../mcp/tools/recording_tool_set.dart';
import '../mcp/tools/terminal_tool_set.dart';
import '../mcp/tools/window_tool_sets.dart';
import '../sessions/launch/conversation_presence.dart';
import '../sessions/launch/handoff_delivery.dart';
import '../sessions/launch/launch_settings.dart';
import '../sessions/launch/session_handoffs.dart';
import '../sessions/launch/server_session_launcher.dart';
import '../sessions/launch/server_session_work.dart';
import '../sessions/launch/session_continuations.dart';
import '../sessions/interrupted_turns.dart';
import '../sessions/session_input.dart';
import '../sessions/delegation_results.dart';
import '../sessions/session_queue.dart';
import '../status/turn_settlement.dart';
import '../sessions/session_ends_with_server.dart';
import '../sessions/session_media.dart';
import '../sessions/session_message_transcripts.dart';
import '../sessions/session_record_readings.dart';
import '../sessions/session_records.dart';
import '../sessions/session_subagents.dart';
import '../sessions/session_agent_stitching.dart';
import '../sessions/session_transcripts.dart';
import '../status/child_turn_wait.dart';
import '../status/hosted_session_wait.dart';
import '../stores/server_store_desk.dart';
import '../agents/server_agents.dart';
import '../automations/daemon_agents.dart';
import '../automations/daemon_automations.dart';
import '../automations/server_resume_runner.dart';
import 'package:karmashala_session/session.dart' show QueuedMessageOrigin;
import 'package:karmashala_session/events.dart'
    show DecisionKind, DecisionOrigin, DecisionRecord;
import '../automations/session_mcp_access.dart';
import '../companion/daemon_companion.dart';
import '../companion/local_relay.dart' show LocalRelayState;
import '../domain/session_registry.dart';
import '../devices/device_app_discovery.dart';
import '../devices/server_device_claims.dart';
import '../devices/server_devices.dart';
import '../env/server_env_vault.dart';
import '../files/server_files.dart';
import '../terminals/server_terminals.dart';
import '../git/server_git.dart';
import '../hooks/hook_endpoint_file.dart';
import '../hooks/hook_server.dart';
import '../hooks/hook_spools.dart';
import '../mcp/tools/store_tool_set.dart';
import '../mcp/tools/usage_tool_set.dart';
import '../mcp/tools/inbox_tool_set.dart';
import '../attention/daemon_attention.dart';
import '../attention/delivery_watch.dart';
import 'package:karmashala_notifications/attention.dart' show InboxItem;
import '../mcp/tools/server_tool_schemas.dart';
import '../browser/server_browser.dart';
import '../flutter/server_flutter_work.dart';
import '../mcp/tools/browser_tool_set.dart';
import '../mcp/tools/build_tool_set.dart';
import '../mcp/tools/device_tool_set.dart';
import '../mcp/tools/flutter_tool_set.dart';
import '../mcp/daemon_mcp.dart';
import '../mcp/mcp_tool_relay.dart';
import '../mcp/tools/instructions_tool_set.dart';
import '../mcp/tools/server_tool_context.dart';
import '../mcp/tools/server_tools.dart';
import '../companion/daemon_worktrees.dart';
import '../automations/daemon_checkout_facts.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import '../domain/uuid.dart';
import '../mcp/tools/checkout_reach.dart';
import '../mcp/tools/project_folders.dart';
import '../mcp/tools/project_tool_set.dart';
import '../mcp/tools/server_verification_runs.dart';
import '../mcp/tools/session_liveness.dart';
import '../mcp/tools/verification_tool_set.dart';
import '../mcp/tools/dev_server_tool_set.dart';
import '../mcp/tools/github_run_tool_set.dart';
import '../mcp/tools/workspace_tool_set.dart';
import '../mcp/tools/session_checkout_tool_set.dart';
import '../mcp/tools/worktree_tool_set.dart';
import '../mcp/tools/decision_tool_set.dart';
import '../mcp/tools/fanout_tool_set.dart';
import '../mcp/tools/inventory_tool_set.dart';
import '../mcp/tools/launch_tool_set.dart';
import '../mcp/tools/notes_todos_tool_set.dart';
import '../mcp/tools/review_thread_tool_set.dart';
import '../mcp/tools/snippet_tool_set.dart';
import '../mcp/tools/session_tool_set.dart';
import '../automations/checks_tool_set.dart';
import 'package:karmashala_host_protocol/protocol.dart'
    show AgentHookEvent, LifecycleEventKind;
import '../pty/pty.dart';
import '../pty/pty_platform.dart';
import '../server/server_administration.dart';
import '../data/conversations_handler.dart';
import '../data/data_service.dart';
import '../data/hosted_run_intents.dart';
import '../server/server_config.dart';
import '../server/server_config_service.dart';
import '../server/server_data_directory.dart';
import '../checkpoints/checkpoint_screenshot_tool_set.dart';
import '../checkpoints/checkpoint_tool_set.dart';
import '../checkpoints/daemon_checkpoints.dart';
import '../sessions/daemon_session_sync.dart';
import '../ssh/ssh_domain.dart';
import '../status/daemon_agent_status.dart';
import '../status/daemon_prompt_answers.dart';
import '../transport/sealed_transport.dart';
import '../transport/socket_transport.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart'
    show settleUnixSockets;
import 'package:karmashala_local_ipc/socket_location.dart';
import 'package:karmashala_host_protocol/host_paths.dart';
import 'host_server.dart';
import 'lifecycle_feed.dart';
import 'session_status_recording.dart';
import 'session_store.dart';
import 'surviving_sink.dart';

part 'serve_command/serve_startup.dart';

/// The daemon. Started detached — `setsid nohup … &` over SSH, or by the app on
/// Windows — and ignores SIGHUP, so an SSH channel closing is not the end of
/// every session on the machine.
///
/// One server, one way: its data directory is `--data-dir=<dir>`, or
/// [defaultServerDataDirectory] (`~/.karmashala`) — the one folder per user
/// per machine the desktop app opens too. The server owns what is in it: it
/// creates and migrates the store (`<dir>/karmashala.sqlite`, refusing one a
/// newer build migrated), reads `<dir>/server.json` (`ServerConfig`, each
/// field overridden by its flag, changed live with `server.config.set`),
/// finds the agent CLIs on its machine at start, and serves phones by that
/// config — off until something turns it on, and then on loopback unless
/// `companion.bind` says otherwise. [paths], [until] and [agentsFor] are for
/// tests.
///
/// [environment] is where the home (for the default data directory) and the
/// host directory are resolved from. It is never defaulted: without
/// `--data-dir` and [environment] — or without [paths] and [environment] —
/// the call is a programming error ([ArgumentError]), so a test cannot
/// reach the real `~/.karmashala` by leaving something out. Only the
/// executable passes `Platform.environment`.
Future<int> runServe(
  List<String> args, {
  Map<String, String>? environment,
  Duration agentScanDelay = const Duration(seconds: 5),
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Future<void>? until,
  ServerAgents Function(DataService data)? agentsFor,
}) async {
  // Nobody may be reading either once the app that started this has quit;
  // a write that fails must cost the line, never the daemon.
  final sink = SurvivingSink(out ?? stdout);
  final errSink = SurvivingSink(err ?? stderr);
  final named = dataDirectoryOf(args);
  if (named == null && environment == null) {
    throw ArgumentError(
      'serve: pass --data-dir=<dir> or the environment to find the home in '
      '— the library never falls back to the real home',
    );
  }
  if (paths == null && environment == null) {
    throw ArgumentError(
      'serve: pass the host directory (paths) or the environment to resolve '
      'it from — the library never falls back to the real home',
    );
  }
  final String dataDirectory;
  try {
    dataDirectory =
        named ?? defaultServerDataDirectory(environment: environment!);
  } on StateError catch (error) {
    errSink.writeln('karmashala_host: refusing to serve — ${error.message}');
    return 2;
  }
  // The config is read, and refused, before anything binds: a server told
  // to bind somewhere it cannot parse must not bind somewhere else.
  final ServerConfigService config;
  try {
    await _ensurePrivateDirectory(dataDirectory);
    config = ServerConfigService(
      dataDirectory: dataDirectory,
      file: await ServerConfig.read(
        dataDirectory,
        log: (message) => errSink.writeln('karmashala_host: $message'),
      ),
      flags: ServerConfig.fromFlags(args),
      hostName: Platform.localHostname,
    );
  } on ServerConfigError catch (error) {
    errSink.writeln('karmashala_host: refusing to serve — $error');
    return 2;
  } on FileSystemException catch (error) {
    errSink.writeln(
      'karmashala_host: refusing to serve — $dataDirectory could not be made '
      'owner-only (${error.message})',
    );
    return 6;
  }
  paths ??= HostPaths.resolve(environment: environment!);
  paths.ensureDirectory();

  // Before the lock: a socket anybody can traverse to is a socket anybody can
  // drive, and there is nothing to authenticate with afterwards.
  final unrestricted = await paths.restrictToCurrentUser();
  if (unrestricted != null) {
    errSink.writeln(
      'karmashala_host: refusing to serve — the socket directory could not be '
      'made owner-only ($unrestricted)',
    );
    return 6;
  }

  // The socket goes where it fits: too long to bind in the host's directory — a
  // long or non-Latin home — and it moves somewhere short and private, proven
  // private before anything binds in it. Nowhere to go is refused in words,
  // not left to the OS's "the length of path exceeds the limit".
  switch (paths.socketLocation) {
    case PreferredSocketLocation():
      break;
    case final FallbackSocketLocation location:
      final refused =
          await prepareFallbackSocketDirectory(location) ??
          await HostPaths(
            Directory(location.directory),
          ).restrictToCurrentUser();
      if (refused != null) {
        errSink.writeln(
          'karmashala_host: refusing to serve — the socket directory could not '
          'be made owner-only ($refused)',
        );
        return 6;
      }
      sink.writeln('karmashala_host socket moved: ${location.reason}');
    case UnplaceableSocket(:final reason):
      errSink.writeln('karmashala_host: refusing to serve — $reason');
      return 6;
  }

  // One host per user per machine: the socket, lock, hook endpoint and
  // MCP credentials are the user's, whatever data directory a server has.
  // The refusal names the other server's data directory, so a second one
  // started beside it says whose socket it met.
  final lock = HostLock.tryAcquire(
    paths.lockPath,
    notePath: paths.holderDataDirectoryPath,
    dataDirectory: dataDirectory,
  );
  if (lock == null) {
    errSink.writeln(
      'karmashala_host: another host is already running for this user '
      '(${HostLock.describeHolder(paths.lockPath, notePath: paths.holderDataDirectoryPath)}); '
      'socket ${paths.socketPath}. One host serves each user on a machine: '
      'stop it (`karmashala_host stop`), or run this one as another user',
    );
    return 3;
  }

  // A socket left by a killed host refuses the bind; we hold the lock, so
  // nothing is listening on it.
  final stale = File(paths.socketPath);
  if (stale.existsSync()) stale.deleteSync();

  final PtyPlatform pty;
  try {
    pty = resolvePtyPlatform();
  } on PtyException catch (e) {
    errSink.writeln('karmashala_host: ${e.message}');
    lock.release();
    return 4;
  }

  // Read before anything binds, so the first client already sees what the last
  // host left — this server's records only: the directory is the user's, and
  // the desktop app's host or another server may have left theirs in it.
  final dataDir = Directory(dataDirectory);
  if (!dataDir.existsSync()) dataDir.createSync(recursive: true);
  final store = SessionStore(
    Directory(paths.sessionsDirectory),
    owner: storeOwnerOf(dataDirectory),
  )..ensureDirectory();
  final registry = SessionRegistry(launcher: pty.launcher, store: store);

  // The server's store, which the desktop app opens beside it: the pairings,
  // the host id and the rows whose lifecycle status this daemon alone
  // writes. A server with no store has nothing to pair into and no rows to
  // launch from: it is refused rather than half there.
  final database = _openStore(dataDirectory, errSink);
  if (database == null) {
    errSink.writeln(
      'karmashala_host: refusing to serve without a store — the line above '
      'says why',
    );
    lock.release();
    return 7;
  }
  final settings = config.settings;
  // What each hosted agent is doing, from the hooks and screens this host
  // holds, and the answers to what they ask.
  late final HostServer server;
  // Filled in below: a row whose agent runs on an SSH box is run here too
  // (slice 5d), through the server's link to the box.
  RemoteSessions? boxSessions;
  final status = DaemonAgentStatus(
    registry: registry,
    database: database,
    publish: (sessionId, body) =>
        server.lifecycle.publishAgentStatus(sessionId, body),
    // An agent on an SSH box is read off the server's copy of its screen.
    remoteScreens: () => boxSessions?.sessions ?? const [],
  );
  // Every client's notes, todos, preferences, workspace and sessions: the
  // desktop app reads and writes them here, a phone's new project is written
  // here, and every row this server writes itself is told through it. The
  // lifecycle status of a session it runs is its own to record.
  final data = DataService(
    database,
    runsSession: (sessionId) {
      final id = hostSessionIdOf(sessionId);
      if (registry.findProcess(id) != null) return true;
      final onBox = boxSessions?.byId(id);
      return onBox != null && !onBox.lifecycle.hasEnded;
    },
  )..ensureEnvironment(localHostEnvironment(DateTime.now().toUtc()));
  // The agents' registry: the shipped agents plus the ACP agents a person
  // added, recomposed as those rows change (ACP design, C2).
  final agentRegistry = AgentRegistryHolder.composed(data.acpAgents)
    ..follow(data);
  // The launch path asks this, so a session can start with an agent added
  // a moment ago; the automations and the companion still hold the shipped
  // registry.
  final liveAgents = DaemonAgents.live(() => agentRegistry.current);
  final prompts = DaemonPromptAnswers(
    status: status,
    database: database,
    onDecision: (decision) => data.announce([DecisionRecorded(decision)]),
  );
  // SSH, reached by the server itself (slice 3a): its pool over the saved
  // hosts, keys read on this machine, and prompts put to the desktop
  // clients — and the Karmashala host on each SSH box (slice 5d): deployed,
  // linked, its sessions started and relayed from here.
  final ssh = ServerSshDomain(
    data: data,
    database: database,
    dataDirectory: dataDirectory,
    log: (message) => errSink.writeln('karmashala_host: $message'),
    // A probe's server (the app started with KARMASHALA_PROBE=1) keeps off
    // every box's host: the owner's sessions are there (PROJECT.md §23).
    probe: (environment ?? Platform.environment)['KARMASHALA_PROBE'] == '1',
  )..attach();
  boxSessions = ssh.remote;
  // A machine's files for every client (slice 3c): the file pane, the
  // editor's reads and saves, Quick Open's index and the watches, over the
  // same SSH pool.
  final files = ServerFiles(
    data: data,
    remoteSpace: ssh.fileSpaceFor,
    defaultDirectoryOf: ssh.defaultDirectoryOf,
    uploadsDirectory: p.join(dataDirectory, 'uploads'),
  )..attach();
  // The variables every terminal this server starts is given (slice 5a):
  // in its own data folder, write-only to every client.
  final envVault = ServerEnvVault(
    dataDirectory: dataDirectory,
    tell: data.announce,
  );
  data
    ..envVault = envVault
    ..greeters.add(envVault.greeting);
  // The app stores, read with credentials only this server holds.
  final storeDesk = ServerStoreDesk(
    dataDirectory: dataDirectory,
    tell: data.announce,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  data
    ..storeWork = storeDesk
    ..greeters.add(storeDesk.greeting);
  // Usage, accounts, detection and the CLI import: the work done for the
  // agents on this machine, whichever client asks, and on its own.
  final hostEnvironment = environment ?? Platform.environment;
  // Every local and WSL terminal (slice 5a): built here on this machine's OS
  // with the vault above, run in the registry, attached to by id.
  final terminals = ServerTerminals(
    registry: registry,
    environments: () => data.environments,
    tell: data.announce,
    overlay: envVault.overlay,
    hostEnvironment: hostEnvironment,
    remote: ssh.remote,
  );
  data.terminalWork = terminals;
  // An ACP agent says its version over the protocol: detection asks each one
  // it finds, in that agent's own environment.
  final acpVersions = AcpVersionProbe(
    runnerFor: ssh.runners.forEnvironment,
    log: sink.writeln,
  );
  // Logging in to an ACP agent: a short-lived connection for its methods and
  // `authenticate`, a terminal tab for a login it runs itself, and the
  // method remembered for its next start.
  final acpAuth = ServerAcpAuth(
    installations: () => data.installations,
    environments: () => data.environments,
    registry: () => agentRegistry.current,
    choices: AcpAuthChoiceDao(database),
    spawn: (environment, request) async => AcpTransport.process(
      await ssh.runners.forEnvironment(environment).start(request),
    ),
    vault: envVault.overlay,
    openTerminal: (login) {
      final paneId = 'acp-login-${newUuid()}';
      final opened = terminals.open(
        TerminalOpen(
          paneId: paneId,
          environmentId: login.environment.id,
          agentLaunch: AgentPaneLaunch(
            agentId: login.agentId,
            executable: login.executable,
            arguments: login.arguments,
            environment: login.variables,
            workingDirectory: login.directory,
            wslDistribution: login.environment.kind == EnvironmentKind.wsl
                ? login.environment.wslDistribution
                : null,
            title: login.title,
          ),
          columns: 120,
          rows: 40,
        ),
      );
      return data.tellIntent(
        OpenTerminalTab(paneId: paneId, title: opened.title),
      );
    },
    openLink: openInThisMachinesBrowser,
  );
  final agentWork = ServerAgentWork(
    data: data,
    acpAuth: acpAuth,
    runners: ssh.runners,
    acpVersion: acpVersions.read,
    hostEnvironment: hostEnvironment,
    // `off`: work only when asked — no usage schedule, no start-up check. For
    // a test's server: its temporary HOME holds no credentials, and its
    // schedule would reach for this machine's Keychain whatever HOME says.
    onItsOwn: hostEnvironment[kAgentWorkVariable] != 'off',
    registry: agentRegistry.current,
    // Detection probes the agents added since, not the ones at start.
    registryHolder: agentRegistry,
  )..attach();
  final companion = DaemonCompanion(
    database: database,
    data: data,
    usageService: agentWork.usage.service,
    registry: registry,
    hostName: settings.name,
    dataDirectory: dataDirectory,
    lanPort: settings.companionPort,
    lanAddress: settings.bind,
    config: settings.companion,
    localRelayEnabled: settings.localRelay,
    localRelayPort: settings.localRelayPort,
    prompts: prompts,
    onLog: (message) => errSink.writeln('karmashala_host: $message'),
  );
  // Session status and attention (slice 5c): every watched session's status
  // — the agents this server runs from its own reading, the rest from hooks
  // and transcripts — what needs a person, and the inbox; decided here and
  // told to every client, a desktop open or not. Phones hear it too.
  final transcripts = TranscriptStores.over(database);
  final attention = DaemonAttention(
    database: database,
    data: data,
    agentStatus: status,
    transcripts: transcripts.all,
    onNewItems: companion.attentionFiled,
    onApprovalRequested: companion.approvalRequested,
    onStatusMoved: companion.sessionsMoved,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  data.attentionWork = attention.attention;
  companion
    ..statusOf = attention.status.reportForOpenId
    ..attentionOf = attention.attentionOf
    ..usageLimitOf = attention.usageLimitOf
    // A phone reads a session's transcript from its agent's own record.
    ..recordIndex = transcripts.all;

  // Agents' tools: the server runs every one that needs no desktop UI
  // itself (slice 2b); the rest are forwarded to the app.
  final tools = ServerToolContext(
    registry: agentRegistry,
    database: database,
    data: data,
    dataDirectory: dataDirectory,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  final reach = CheckoutReach(database, runners: ssh.runners);
  // A project an agent adds imports the CLI history of its new checkouts.
  final folders = ProjectFolders(
    tools,
    reach,
    onRecorded: agentWork.imports.checkoutsRecorded,
  );
  final liveness = SessionLiveness(
    (id) => registry.findProcess(hostSessionIdOf(id)) != null,
  );
  final worktrees = daemonWorktrees(
    database: database,
    registry: registry,
    facts: DaemonCheckoutFacts(CheckoutRows(database)),
    newId: newUuid,
    record: data.recordWorktreeSetup,
    environmentOf: reach.environmentOf,
    runners: ssh.runners,
    // A box's setup command runs as a session of the box's host (slice 5d).
    remote: ssh.remote,
  );
  // The browser, Flutter runs and builds (slice 3d): a Chrome on this
  // machine, and commands run as sessions this server hosts, any client
  // attaches to — with every client closed as much as with one open.
  final browser = ServerBrowser(
    database: database,
    dataDirectory: dataDirectory,
    tell: data.announce,
    hostEnvironment: hostEnvironment,
  );
  data.browserWork = browser;
  // The devices on this machine (slice 4a): one claims registry — agents'
  // device tools, flutter run and a pane here answer to it, and every client
  // hears who holds what — and the adb every one of them resolves the same way.
  final deviceClaims = ServerDeviceClaims(
    database: database,
    tell: data.announce,
  )..start();
  data
    ..watchers.add(deviceClaims.watch)
    ..greeters.add(deviceClaims.greeting);
  final devices = ServerDevices(
    database: database,
    claims: deviceClaims,
    runners: ssh.runners,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  final flutter = ServerFlutterWork(
    claims: deviceClaims,
    androidSdkRoot: devices.androidSdkRoot,
    registry: registry,
    database: database,
    tell: data.announce,
    dataDirectory: dataDirectory,
    hostEnvironment: hostEnvironment,
    runners: ssh.runners,
    log: (message) => errSink.writeln('karmashala_host: $message'),
    // Runs and builds on an SSH box are sessions of its host (slice 5d).
    remote: ssh.remote,
  );
  data
    ..flutterWork = flutter
    ..streamSources[kFlutterLogsStream] = flutter.logs;
  // Each run started is shown in the window a person last used (slice 5b).
  HostedRunIntents(data).attach();
  // A phone on this machine announcing a Flutter app is attached while the
  // apps are being looked at — with no client on this machine at all.
  final appDiscovery = DeviceAppDiscovery(
    adb: devices.adb,
    offer: ({required hostUri, required serial}) async {
      try {
        await flutter.apps.attach(hostUri.toString(), deviceSerial: serial);
      } on FlutterAppException {
        // Nothing answered there; the registry says why.
      }
    },
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  flutter.apps.onLooked = () => unawaited(appDiscovery.looked());
  final checkoutRows = CheckoutRows(database);
  // Which sessions the person let operate Karmashala: read per call, so
  // a grant given a moment ago counts on the next tool call.
  final grantRows = SessionDao(database);
  final worktreeTools = WorktreeToolSet(
    tools,
    reach: reach,
    folders: folders,
    worktrees: worktrees,
    liveness: liveness,
  );
  final mcpTools = McpToolRelay(
    operatorGranted: (sessionId) =>
        grantRows.getById(sessionId)?.operatorGranted ?? false,
    tools: ServerTools([
      const InstructionsToolSet(),
      InventoryToolSet(tools),
      NotesTodosToolSet(tools),
      DecisionToolSet(tools),
      ReviewThreadToolSet(
        tools,
        anchors: LocalReviewAnchors(database, reach: reach),
      ),
      SnippetToolSet(tools),
      FanOutToolSet(tools),
      WorkspaceToolSet(
        tools,
        reach: reach,
        folders: folders,
        worktreesOf: worktrees.list,
        liveness: liveness,
      ),
      GitHubRunToolSet(tools, reach: reach),
      ProjectToolSet(tools, reach: reach, folders: folders),
      worktreeTools,
      // An agent attaches the checkouts its session spans — any of them,
      // when the session has no project of its own.
      SessionCheckoutToolSet(tools, worktrees: worktreeTools),
      VerificationToolSet(
        ServerVerificationRuns(tools, browser: browser, devices: devices),
      ),
    ]),
  );
  server =
      HostServer(
          registry: registry,
          ptyLibrary: pty.library,
          companion: companion,
          build: hostBuildOf(Platform.resolvedExecutable),
        )
        ..prompts = prompts
        // A client attached to a box's session is relayed its frames (5d).
        ..boxes = ssh.relay;
  // A desktop client on another machine, over the companion's sealed
  // channel (slice 5e), is one more connection with its pairing's grants.
  final hostServer = server;
  companion.onHostLink = (link) {
    final connection = SealedHostConnection(link);
    unawaited(hostServer.serveConnection(connection, trust: connection.trust));
  };
  server.lifecycle.statusSnapshot = status.snapshot;
  // Every turn's before and after checkpoints, taken here (slice 2b): off the
  // status of a session this server runs, and off the hooks of any other
  // row on this machine. A tool is held until its turn's checkpoint exists.
  final checkpoints = DaemonCheckpoints(
    database: database,
    data: data,
    heldHere: status.runsHere,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  data.checkpointWork = checkpoints.handle;
  checkpoints.start(status.changes);
  mcpTools.tools.add(CheckpointToolSet(checkpoints));
  // Pictures filed against a checkpoint, and two of them compared.
  final screenshotDirectory = p.join(dataDirectory, 'checkpoint-screenshots');
  mcpTools.tools.add(
    CheckpointScreenshotToolSet(
      checkpoints: checkpoints,
      screenshots: CheckpointScreenshotDao(database),
      browser: browser,
      devices: devices,
      directory: screenshotDirectory,
    ),
  );
  // Folders of checkpoints dropped without their files, by any path.
  unawaited(
    sweepCheckpointScreenshotFolders(
      screenshotDirectory,
      CheckpointDao(database).exists,
    ),
  );
  status.start();
  attention.start();
  final recording = SessionStatusRecording(
    server.lifecycle,
    database,
    clock: () => DateTime.now().toUtc(),
    onWritten: (sessionId) => data.announceSessions([sessionId]),
    // An agent spoken to over ACP runs inside this server: a row of one left
    // `running` by the server before this one ended with it.
    resolveUnknown: sessionEndsWithServer(
      rows: checkoutRows,
      agents: liveAgents,
    ),
  )..start();
  // A box's sessions start and exit as its host says (slice 5d).
  ssh.onBoxLifecycle = recording.applyRemote;
  final companionServing = await _startCompanion(
    companion,
    server.lifecycle,
    errSink,
  );
  // Title sync, attribution and adoption: the server's, over its own store
  // and this machine's agent stores, over the panes of its own terminals.
  final sessionSync = DaemonSessionSync(
    database: database,
    data: data,
    registry: registry,
    // The panes are the server's own terminals (slice 5c), read off its own
    // screens; no client reports them.
    panes: terminals,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  terminals.onPanesChanged = sessionSync.panesChanged;
  // A hook an agent on an SSH box fired, relayed by the box's host: its
  // status and what it needs of a person, as this machine's own.
  ssh.onBoxHook = (hook) {
    status.hook(hook);
    attention.hook(hook);
    sessionSync.hook(hook);
    server.lifecycle.relayHook(hook);
  };
  sessionSync.start();
  // Git, worktrees, their cleanup and GitHub for every client (slice 3b); a
  // turn ending tells them where to read again.
  final git = ServerGit(
    database: database,
    data: data,
    // Git for the clients runs wherever a checkout lives: this machine, WSL
    // from Windows, and an SSH box over the server's own connection.
    reach: reach,
    worktrees: worktrees,
    // A project added or rescanned by a client imports the CLI history of
    // its new checkouts, as an agent's does.
    folders: folders,
    hostsSession: (id) => registry.findProcess(hostSessionIdOf(id)) != null,
    livePaneDirectories: () => [
      for (final pane in sessionSync.panes.all)
        if (pane.live) ?pane.workingDirectory,
    ],
    onItsOwn: hostEnvironment[kWorktreeCleanupVariable] != 'off',
    log: (message) => errSink.writeln('karmashala_host: $message'),
  )..attach();
  checkpoints.recorder.onTurnEnded = git.turnEnded;
  // Every live session's delivery, read here (slice 5c): the pull request
  // and its checks, on the server's own two-minute poll and when a turn ends
  // in a checkout — news filed, readings told to every window, a phone's
  // stage answered. Off for a test's server.
  final delivery = DeliveryWatch(
    database: database,
    git: git.handle,
    tell: data.announce,
    news: attention.attention.deliveryRead,
    lookingAt: () => attention.attention.lookingAt,
    runs: attention.runs,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  data
    ..addChangeListener(delivery.changed)
    ..greeters.add(delivery.greeting);
  companion.deliveryStageOf = delivery.stageOf;
  if (hostEnvironment[kDeliveryPollVariable] != 'off' &&
      hostEnvironment[kAgentWorkVariable] != 'off') {
    delivery.start();
  }
  final hookServer = await _openHookServer(
    paths,
    // The status first, so a watcher hears the status a hook moved no later
    // than the hook itself; then what the server does with it itself.
    (hook) {
      // The checkpoint first: it files the prompt and paths before the
      // status moves; the hook server awaits its hold.
      final held = checkpoints.hook(hook);
      status.hook(hook);
      attention.hook(hook);
      sessionSync.hook(hook);
      server.lifecycle.relayHook(hook);
      return held;
    },
    errSink,
  );
  // The WSL agents' hook spools, drained here (slice 5a): a WSL agent cannot
  // reach this server's loopback endpoint, so its hook script writes a file.
  // Never held — its tool has already run. Only the real server drains them
  // (a Windows one, in its own default data folder): a probe's or a test's
  // would take the owner's payloads.
  final spools =
      Platform.isWindows &&
          named == null &&
          hostEnvironment[kAgentWorkVariable] != 'off' &&
          hostEnvironment[kHookSpoolsVariable] != 'off'
      ? (HookSpools(
          sources: _wslSpoolSources(database),
          onHook: (hook) {
            checkpoints.spooled(hook);
            status.hook(hook);
            attention.hook(hook);
            sessionSync.hook(hook);
            server.lifecycle.relayHook(hook);
          },
        )..start())
      : null;
  final mcp = await _openMcp(
    paths,
    dataDirectory,
    mcpTools,
    database,
    settings.mcpPort,
    errSink,
  );
  // Every agent this server starts — a person's, a phone's, an automation's
  // — is one of its own terminals, under the session's own id, so
  // `terminal_list` and the windows see it (slice 5b).
  Future<void> openAgent(AgentPaneLaunch launch, int columns, int rows) async {
    await terminals.openAnywhere(
      TerminalOpen(
        paneId: 'session-${launch.sessionId}',
        agentLaunch: launch,
        columns: columns,
        rows: rows,
      ),
    );
  }

  // A phone starts and resumes sessions here with no app, once a launched
  // agent can be handed its tools.
  companion.serveSessions(
    mcp: SessionMcpAccessPoint(
      mcp: mcp,
      configDirectory: p.join(dataDirectory, 'mcp'),
    ),
    openAgent: openAgent,
  );
  // An agent whose adapter speaks ACP runs in a runtime of the server's, not
  // a PTY: its conversation is `session_messages`, its status its own word.
  final sessionMessages = SessionMessageDao(database);
  final acpHost = ServerAcpHost(
    agentStatus: status,
    checkpoints: checkpoints,
    data: data,
    titles: AcpTitles(sessionSync.rows),
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  final sessionUsage = SessionUsageDao(database);
  final acpRuntimes = AcpRuntimes(
    messages: sessionMessages,
    usage: sessionUsage,
    host: acpHost,
    openLink: openInThisMachinesBrowser,
    runnerFor: (environment) => const CommandRunnerFactory().forEnvironment(
      environment ?? localHostEnvironment(DateTime.now().toUtc()),
    ),
  );
  final automations = await _startAutomations(
    database: database,
    data: data,
    recording: recording,
    registry: registry,
    server: server,
    mcp: mcp,
    mcpTools: mcpTools,
    dataDirectory: dataDirectory,
    errSink: errSink,
    agentStatus: status,
    remote: ssh.runners,
    usage: ServiceResumeUsage(
      agentWork.usage.service,
      environments: () => data.environments,
    ),
    // A usage limit is filed in the server's inbox, and what was done about
    // it told to every window (slice 5c).
    raise: attention.attention.raise,
    noticeUsageLimit: (notice) => data.announce([UsageLimitNoticed(notice)]),
    openAgent: openAgent,
    // Automations and resumes fire on an SSH box it reaches (slice 5d).
    reachesBox: ssh.remote.reaches,
    // A resume of an ACP session that ended starts it again over ACP.
    acpRuntimes: acpRuntimes.start,
    acpAuth: acpAuth.startAuth,
  );
  // Event rules and usage limits follow every status the server keeps,
  // app or no app.
  final statusFollow = automations == null
      ? null
      : attention.status.statusChanges.listen(automations.observeStatus);
  // The one launch path (slice 5b): a person's New session, a resume, an
  // agent's open_new_session, a handoff, a fork — each decided here and
  // started as one of this server's terminals, under the session's own id.
  final sessionRows = SessionDao(database);
  LaunchSettings launchSettings() =>
      LaunchSettings.parse(database.readMetadata(kLaunchSettingsKey));
  // A client that subscribes after an ACP agent started is greeted with the
  // modes and options the runtime announced before it arrived.
  final acpModes = AcpSessionModes(
    runtimeOf: status.acpRuntimeOf,
    running: () => registry.acpRuntimes,
  );
  data
    ..sessionModes = acpModes
    ..greeters.add(acpModes.greeting);
  data.liveAcpSessions = () => {
    for (final runtime in registry.acpRuntimes)
      if (!runtime.lifecycle.hasEnded) runtime.sessionId,
  };
  // The texts a launch hands its agent: rows, and temp files only while used.
  final handoffs = SessionHandoffs(
    dao: SessionHandoffDao(database),
    root: SessionHandoffs.rootFor(dataDirectory),
    now: () => DateTime.now().toUtc(),
    legacy: Directory(p.join(dataDirectory, 'handoff')),
  );
  final hostedLauncher = HostedAgentLauncher(
    registry: registry,
    agents: liveAgents,
    sessions: sessionRows,
    mcp: SessionMcpAccessPoint(
      mcp: mcp,
      configDirectory: p.join(dataDirectory, 'mcp'),
    ),
    now: () => DateTime.now().toUtc(),
    newId: newUuid,
    worktrees: worktrees,
    onRowWritten: (sessionId) => data.announceSessions([sessionId]),
    environmentOf: checkoutRows.environment,
    openAgent: openAgent,
    settings: launchSettings,
    hasUsableLogin: (installation) async {
      final signIn = await agentWork.accounts.current(installation.id);
      return signIn is AnthropicSignIn && signIn.usableLogin;
    },
    runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
      checkoutRows.environment(id) ??
          localHostEnvironment(DateTime.now().toUtc()),
    ),
    vaultNames: () => {for (final name in envVault.names) name.name},
    handoffs: handoffs,
    links: SessionRepositoryDao(database),
    acpRuntimes: acpRuntimes.start,
    acpAuth: acpAuth.startAuth,
    hostEnvironment: hostEnvironment,
  );
  final checkoutFacts = DaemonCheckoutFacts(
    checkoutRows,
    agents: liveAgents,
    reachesBox: ssh.remote.reaches,
  );
  final presence = ConversationPresenceReader(
    locator: CliStoreLocator(
      runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
        checkoutRows.environment(id) ??
            localHostEnvironment(DateTime.now().toUtc()),
      ),
      installations: data.installations,
      environment: hostEnvironment,
    ),
    environmentsHere: () => [
      for (final environment in data.environments)
        if (checkoutFacts.isHere(environment)) environment,
    ],
  );
  // Where an agent's settings are on the machine a scratch folder is on: the
  // folder's machine, with this one and Windows beside it, which a WSL home
  // is reached through.
  final scratchTrust = AgentFolderTrust(
    registry: () => agentRegistry.current,
    storeHome: (environmentId, agentId) async {
      final environments = [
        for (final e in data.environments)
          if (e.id == environmentId ||
              e.kind == EnvironmentKind.windowsNative ||
              e.kind == EnvironmentKind.localPosix)
            e,
      ];
      final stores = await CliStoreLocator(
        runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
          checkoutRows.environment(id) ??
              localHostEnvironment(DateTime.now().toUtc()),
        ),
        installations: data.installations,
        environment: hostEnvironment,
      ).locate(environments);
      return stores
          .where((s) => s.environmentId == environmentId)
          .firstOrNull
          ?.homeFor(agentId);
    },
  );
  final launches = ServerSessionLauncher(
    launcher: hostedLauncher,
    agents: liveAgents,
    registry: registry,
    sessions: sessionRows,
    rows: checkoutRows,
    facts: checkoutFacts,
    installationsIn: data.installationsIn,
    settings: launchSettings,
    presenceOf: presence.presenceOf,
    repairAgents: () async {
      await agentWork.detection.repair();
    },
    discardFailedScratch: folders.discardFailedScratch,
    trustScratchFolder: (installation, folder) async {
      final where = data.environments
          .where((e) => e.id == folder.environmentId)
          .firstOrNull;
      if (where == null) return;
      await scratchTrust.trust(
        agentId: installation.agentId,
        folder: folder,
        windowsAgent: where.kind == EnvironmentKind.windowsNative,
      );
    },
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  final sessionWaits = HostedSessionWait(status: prompts.status);
  final typist = SessionToolSet.typistOver(prompts);
  // A switch in place asks the queue and the transcripts, made below.
  SessionQueue? switchQueue;
  SessionTranscripts? switchTranscripts;
  final agentSpans = SessionAgentSpanDao(database);
  final continuations = SessionContinuations(
    launches: launches,
    sessions: sessionRows,
    rows: checkoutRows,
    decisions: DecisionRecordDao(database),
    checkpoints: CheckpointDao(database),
    reach: reach,
    transcripts: TranscriptStores.over(database),
    carryDecision: (record) => data.applyAsServer(DecisionAppend(record)),
    forks: checkpoints,
    waits: sessionWaits,
    send: typist.send,
    spans: agentSpans,
    conversationOf: (sessionId) async =>
        await switchTranscripts?.messagesOf(sessionId) ?? const [],
    turnRunning: (sessionId) => switchQueue?.busy(sessionId) ?? false,
    cancelResume: (sessionId, reason) =>
        automations?.cancelResumeOf(sessionId, reason) != null,
    holdQueue: (sessionId) => switchQueue?.hold(sessionId),
    releaseQueue: (sessionId) => switchQueue?.release(sessionId),
    nextMessageOrdinal: sessionMessages.countForSession,
    onSwitched: (sessionId, spans) {
      data.announceSessions([sessionId]);
      final row = sessionRows.getById(sessionId);
      if (row == null) return;
      data.announce([
        SessionAgentChanged(
          sessionId: sessionId,
          agentInstallationId: row.agentInstallationId,
          spans: spans,
        ),
      ]);
    },
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  final sessionWork = ServerSessionWork(
    launches: launches,
    continuations: continuations,
  );
  data.sessionWork = sessionWork;
  // A client's chat sends and Stop (`sessions.send`, `.interrupt`), typed by
  // the same typist as MCP `session_send`.
  // An agent spoken to over ACP that nothing runs is resumed here to take a
  // client's message, whichever client sent it.
  final speaksAcp = sessionSpeaksAcp(
    rows: checkoutRows,
    agents: liveAgents,
    sessionOf: sessionRows.getById,
  );
  // Every send — a client's, an agent's `session_send`, the older companion
  // API's — waits here while the session's turn runs.
  // The one decision whether a turn still runs: the queue, a switch and the
  // open-turn record all read it.
  final turnSettlement = TurnSettlement(status: prompts.status)..start();
  final sessionQueue = SessionQueue(
    dao: SessionQueueDao(database),
    status: prompts.status,
    turns: turnSettlement,
    // A person's pause outlives a restart: it is theirs to lift.
    readPaused: () => database.readMetadata(kQueuePausedKey),
    writePaused: (value) => database.writeMetadata(kQueuePausedKey, value),
    resumesOnSend: speaksAcp,
    // A PTY session nothing runs is resumed for its queue, never left
    // holding it.
    resumeStopped: (sessionId, prompt) =>
        launches.resume(sessionId, prompt: prompt),
    takesOpeningMessage: (sessionId) {
      final session = sessionRows.getById(sessionId);
      final agentId = session == null
          ? null
          : checkoutRows.installation(session.agentInstallationId)?.agentId;
      return agentId != null &&
          (liveAgents.descriptorOf(agentId)?.launch.acceptsPromptArgument ??
              false);
    },
    // A message is not typed over what a person is typing in the pane.
    personTypedAt: (sessionId) =>
        prompts.status.runningSessionOf(sessionId)?.token.lastActiveAt,
    // A limit holds the queue until its resume, which sends the head.
    limitHold: (sessionId) {
      final session = sessionRows.getById(sessionId);
      return usageLimitQueueHold(
        live: automations?.liveResumeFor(sessionId),
        report: prompts.status.statusOf(sessionId)?.report,
        agentId: session == null
            ? null
            : checkoutRows.installation(session.agentInstallationId)?.agentId,
      );
    },
    announce: (sessionId, open) => data.announce([
      SessionQueueChanged(sessionId: sessionId, messages: open),
    ]),
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  switchQueue = sessionQueue;
  automations
    ?..resumeQueue = sessionQueue
    ..resumesMoved = sessionQueue.refreshAll;
  // A person's End pauses what waits, so nothing resumes what they ended.
  sessionWork.ending = sessionQueue.pause;
  final sessionInput = SessionInput(
    prompts: prompts,
    typist: typist,
    resumesOnSend: speaksAcp,
    resume: (sessionId, prompt) => launches.resume(sessionId, prompt: prompt),
    queue: sessionQueue,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  // Turns the last stop or crash cut off are continued now, each resume
  // claimed before any client can connect and reopen the same row; then
  // every turn this server runs is recorded open until it settles.
  final openTurns = OpenTurns(
    read: () => database.readMetadata(kOpenTurnsKey),
    write: (value) => database.writeMetadata(kOpenTurnsKey, value),
  );
  if (hostEnvironment[kAgentWorkVariable] != 'off') {
    unawaited(
      InterruptedTurnContinuer(
        turns: openTurns,
        sessionOf: sessionRows.getById,
        childrenOf: sessionRows.childrenOf,
        runsHere: launches.runsHere,
        takesOpeningMessage: (session) {
          final agentId = checkoutRows
              .installation(session.agentInstallationId)
              ?.agentId;
          if (agentId == null) return false;
          // Over ACP the message is the first `session/prompt`.
          return liveAgents.adapterOf(agentId)?.acp != null ||
              (liveAgents.descriptorOf(agentId)?.launch.acceptsPromptArgument ??
                  false);
        },
        // A window connected by the time the agent is back shows it, as
        // `session_send`'s resume does; the inbox item covers one that is not.
        resume: (sessionId, prompt) async {
          final started = await launches.resume(sessionId, prompt: prompt);
          data.tellIntent(
            OpenSessionTab(
              sessionId: started.sessionId,
              title: started.session.title,
              launch: started.launch,
            ),
          );
        },
        now: () => DateTime.now().toUtc(),
        enabled: () =>
            continuesInterruptedTurns(database.readMetadata('settings.v1')),
        report: attention.turnCutOff,
        log: (message) => errSink.writeln('karmashala_host: $message'),
      ).run(),
    );
  }
  final turnFollow = followOpenTurns(
    openTurns,
    statuses: status.changes,
    lifecycle: server.lifecycle.events,
    runsHere: status.runsHere,
    clock: () => DateTime.now().toUtc(),
    settled: turnSettlement.settled,
  );
  sessionQueue.start();
  final handoffDelivery = HandoffDelivery.forServer(
    handoffs: handoffs,
    status: prompts.status,
    turns: turnSettlement,
    deliver: (sessionId, text, leadIn) =>
        sessionInput.deliverNow(sessionId, text, leadIn: leadIn),
    leadInFor: (sessionId) =>
        prompts.agentOf(sessionId)?.terminal.typedOpeningLeadIn,
    queue: sessionQueue,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  handoffs.onPending = handoffDelivery.watch;
  sessionSync.titles.openedByPointer = (row) =>
      handoffs.openedByPointer(row.id);
  Set<String> liveSessions() => {
    for (final row in sessionRows.getClaimingLive()) row.id,
  };
  final legacyHandoffs = handoffs.sweepLegacy(live: liveSessions());
  final sweptHandoffs = handoffs.sweep(live: liveSessions());
  if (legacyHandoffs + sweptHandoffs > 0) {
    errSink.writeln(
      'karmashala_host: handoffs: swept $legacyHandoffs old file(s) and '
      '$sweptHandoffs row(s) or folder(s)',
    );
  }
  handoffDelivery.start();
  final handoffSweep = Timer.periodic(
    const Duration(hours: 1),
    (_) => handoffs.sweep(live: liveSessions()),
  );
  // A process starting or ending tells what waits for it: a start-up is a
  // turn whose end delivers; an end leaves nothing running it.
  final queueEnds = server.lifecycle.events.listen((event) {
    if (event.kind == LifecycleEventKind.started) {
      sessionQueue.hostSessionStarted(event.sessionId);
    } else {
      sessionQueue.hostSessionEnded(event.sessionId);
    }
  });
  data.sessionInput = sessionInput;
  // A phone on the older companion API sends to such a session the same way;
  // to a PTY session it types its own keys, so only the queue's decision is
  // taken here.
  companion.sendOverProtocol = (sessionId, text) async {
    if (!speaksAcp(sessionId)) {
      return sessionQueue.queueIfBusy(
            sessionId,
            text,
            origin: QueuedMessageOrigin.companion,
          ) !=
          null;
    }
    try {
      await sessionInput.handle(
        SessionSend(sessionId: sessionId, text: text),
        null,
        origin: QueuedMessageOrigin.companion,
      );
    } on DataRefused catch (refusal) {
      throw StateError(refusal.message);
    }
    return true;
  };
  // Sessions' transcripts for any client (`sessions.transcript`): read here,
  // where the agents write them.
  final sessionTranscripts = SessionTranscripts(
    lookUp: (sessionId) => lookUpSessionRecord(
      sessionId,
      imported: ImportedSessionDao(database),
      sessions: sessionRows,
      installation: checkoutRows.installation,
      locate: transcripts.recordFor,
      registry: transcripts.registry,
    ),
    // An ACP session's transcript is the rows its runtime wrote (C3).
    messages: SessionMessageTranscriptSource(sessionMessages),
    servesFromMessages: speaksAcp,
    // A pointer opening reads as the message it stood for.
    openingBehindPointer: handoffs.openingBehindPointer,
    // A session that switched agent is read span by span.
    spans: AgentSpanReaders(
      spansOf: (sessionId) {
        final all = agentSpans.forSession(sessionId);
        final row = all.isEmpty ? null : sessionRows.getById(sessionId);
        if (row == null) return all;
        return [
          ...all.take(all.length - 1),
          all.last.copyWith(externalSessionId: row.externalSessionId),
        ];
      },
      agentIdOf: (installationId) =>
          checkoutRows.installation(installationId)?.agentId,
      speaksAcp: (installationId) {
        final agentId = checkoutRows.installation(installationId)?.agentId;
        return agentId != null && liveAgents.adapterOf(agentId)?.acp != null;
      },
      locate: transcripts.recordFor,
    ),
  );
  switchTranscripts = sessionTranscripts;
  acpHost.transcriptsChanged = sessionTranscripts.messagesChanged;
  data.sessionTranscripts = sessionTranscripts;
  // A live session idle over background work it started still reads working,
  // by the runs the chat lists.
  attention.status.backgroundRunsOf = (session) async => [
    for (final message in await sessionTranscripts.messagesOf(session.openId))
      ?message.background,
  ];
  // Rewind points, changed files and the open question (Stage 0 step 7):
  // the adapters' readers of raw lines, run over the same records; and each
  // session's counts with its agent's lifetime totals (step 9).
  final sessionRecordReadings = SessionRecordReadings(
    lookUp: sessionTranscripts.lookUp,
    registry: transcripts.registry,
    sessions: sessionRows,
    rows: checkoutRows,
    runners: ssh.runners,
    storeHome: transcripts.storeHome,
    readRows: readSqliteRows,
    // An ACP session's counts come from the rows and usage this server kept.
    messages: sessionMessages,
    usage: sessionUsage,
    speaksAcp: speaksAcp,
  );
  data.sessionRecordReadings = sessionRecordReadings;
  prompts.readQuestion = sessionRecordReadings.openQuestion;
  // Sessions' pictures (Stage 0 step 10), extracted from the same records.
  data.sessionMedia = SessionMedia(
    lookUp: sessionTranscripts.lookUp,
    registry: transcripts.registry,
    root: p.join(dataDirectory, 'media'),
  );
  // A session's subagents and child sessions, from the same records and the
  // status this server keeps.
  final sessionSubagents = SessionSubagents(
    messagesOf: sessionTranscripts.messagesOf,
    childrenOf: sessionRows.childrenOf,
    liveStateOf: (sessionId) => status.holds(sessionId)
        ? liveSubagentState(status.statusOf(sessionId)?.report)
        : null,
    agentNameOf: (session) {
      final agentId = checkoutRows
          .installation(session.agentInstallationId)
          ?.agentId;
      return agentId == null ? null : liveAgents.nameOf(agentId);
    },
    sessionTokens: sessionRecordReadings.tokensOf,
    subagentTokens: sessionRecordReadings.subagentTokensOf,
    speaksAcp: speaksAcp,
    switched: agentSpans.hasSpans,
  );
  data.sessionSubagents = sessionSubagents;
  // What a session said last, read from its record: `subagent_run`'s answer
  // and `session_wait`'s.
  Future<({String text, DateTime? at})?> answerOf(
    String sessionId, {
    DateTime? since,
  }) async {
    try {
      return lastAgentAnswer(
        await sessionTranscripts.messagesOf(sessionId),
        since: since,
      );
    } on Object {
      return null;
    }
  }

  final childTurns = ChildTurnWait(
    waits: sessionWaits,
    answerOf: answerOf,
    settled: turnSettlement.settled,
  );
  Future<void> endChild(String sessionId) async {
    final id = hostSessionIdOf(sessionId);
    if (registry.findProcess(id) != null) await registry.close(id);
  }

  // An async child's result is pushed into its parent's queue when its turn
  // ends; a person's Stop on the child keeps it theirs.
  final delegations = DelegationResults(
    turnOf: (childId, since) =>
        childTurns.firstTurn(childId, bound: kDelegationBound, since: since),
    answerOf: answerOf,
    queue: sessionQueue,
    store: SessionDelegationDao(database),
    isLive: prompts.status.holds,
    endChild: endChild,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  )..start();
  sessionInput.interrupted = delegations.stopped;
  // Recordings the server writes itself (slice 5b): a terminal's output as
  // an asciicast, and its own machine's devices.
  final recordings = RecordingToolSet.over(
    terminals: terminals,
    registry: registry,
    recordingsDirectory: p.join(dataDirectory, 'recordings'),
    devices: devices,
  );
  // `checks_run` for a checkout on this machine or an SSH box is the
  // automations'.
  mcpTools.tools
    ..add(ChecksToolSet(automations?.localTool ?? (_, _, _) => null))
    // Every session is operated here: every agent runs in this server.
    ..add(
      SessionToolSet(
        tools,
        prompts: prompts,
        registry: registry,
        waits: sessionWaits,
        queue: sessionQueue,
        typist: typist,
        answerOf: answerOf,
        sentBy: delegations.sent,
        endedBy: delegations.endedBy,
        resumeWith: (sessionId, prompt) async {
          final started = await launches.resume(sessionId, prompt: prompt);
          data.tellIntent(
            OpenSessionTab(
              sessionId: started.sessionId,
              title: started.session.title,
              launch: started.launch,
            ),
          );
        },
      ),
    )
    // An agent's `open_new_session` and `subagent_run`, through the one
    // launch path.
    ..add(
      LaunchToolSet(
        tools,
        launches: launches,
        agents: liveAgents,
        reach: reach,
        folders: folders,
        turns: childTurns,
        tokensOf: (sessionId) async =>
            (await sessionRecordReadings.tokensOf(sessionId)).total,
        endChild: endChild,
        callHolds: openTurns.heldByCall,
        delegate: delegations.watch,
      ),
    )
    // `get_usage` is read here from the server's own usage (slice 2a).
    ..add(UsageToolSet(agentWork.usage))
    ..add(StoreToolSet(storeDesk))
    // The inbox is the server's (slice 5c), app or no app.
    ..add(InboxToolSet(attention.attention))
    // The browser, the Flutter loop and builds are the server's (slice 3d).
    ..add(BrowserToolSet(browser))
    ..add(
      FlutterToolSet(
        apps: flutter.apps,
        loop: flutter.loop,
        rows: checkoutRows,
        configurations: flutter.configurations,
      ),
    )
    ..add(BuildToolSet(builds: flutter.builds, rows: checkoutRows))
    // list_devices and device_* drive this machine's devices (slice 4a).
    ..add(DeviceToolSet(devices))
    // What the app's own tools did, the server's since slice 5b: a window
    // is only asked to show the result.
    ..add(OpenSessionToolSet(tools, launches: launches))
    ..add(ContinuationToolSet(tools, continuations: continuations))
    ..add(TerminalToolSet(terminals: terminals, registry: registry, data: data))
    ..add(DevServerToolSet(terminals))
    ..add(recordings)
    ..add(SnippetInsertToolSet(tools, terminals: terminals))
    ..add(SessionDraftToolSet(tools))
    ..add(SelectCheckoutToolSet(tools));
  // A client composes its catalogue from `serverToolSchemas`: a family
  // served here but missing there is a tool no client lists (found once).
  assert(
    _names(mcpTools.tools.schemas).join(',') ==
        _names(serverToolSchemas).join(','),
    'serverToolSchemas does not list what serve registers',
  );
  // `server.config.set` brings the phone listener in line at once.
  if (companionServing) {
    config.apply = (settings) => companion.reconfigure(
      config: settings.companion,
      lanAddress: settings.bind,
      lanPort: settings.companionPort,
      localRelayEnabled: settings.localRelay,
      localRelayPort: settings.localRelayPort,
    );
  }
  // Devices, revoke, agents and the config, from `karmashala_host` and the
  // desktop app on this machine; the server looks for its agent CLIs now.
  final agents =
      (agentsFor ??
      (data) => ServerAgents(
        data: data,
        registryHolder: agentRegistry,
        acpVersion: acpVersions.read,
      ))(data);
  server.data = data;
  server.admin = ServerAdministration(
    companion: companionServing ? companion : null,
    agents: agents,
    config: config,
    dataDirectory: dataDirectory,
  );
  final remembered = registry.sessions.length;
  final listener = await UnixSocketHostListener.bind(paths.socketPath);

  final stopping = Completer<int>();
  void stop(int code) {
    if (!stopping.isCompleted) stopping.complete(code);
  }

  // `karmashala_host stop` on Windows asks rather than kills (stopNow).
  server.onStopRequested = () => stop(0);

  // Not in the first moments: the probe starts a dozen processes, and a
  // server SIGKILLed while the VM is between fork and exec for one of them
  // can leave that half-born child behind for good, holding the socket —
  // connections accepted, never answered (found live: a start killed at
  // once). A server killed that early probes nothing; `agents.refresh`
  // still probes at once when asked.
  unawaited(
    Future<void>.delayed(agentScanDelay).then((_) async {
      if (stopping.isCompleted) return;
      try {
        final scan = await agents.refresh();
        sink.writeln('agents: ${scan.summary}');
      } on Object catch (error) {
        errSink.writeln('karmashala_host: agent probe failed ($error)');
      }
      if (stopping.isCompleted) return;
      await agentWork.start(log: sink.writeln);
    }),
  );

  // The sessions an SSH box kept while this server was down: a copy of each
  // is kept again, so their status, exits and panes are read as before
  // (slice 5d). Only boxes a row still claims to run on are dialled.
  unawaited(
    Future<void>.delayed(agentScanDelay).then((_) async {
      final hostIds = <String>{};
      for (final row in sessionRows.getClaimingLive()) {
        final path =
            row.worktree ?? checkoutRows.repository(row.repositoryId)?.path;
        final hostId = path == null
            ? null
            : checkoutRows.environment(path.environmentId)?.sshHostId;
        if (hostId != null) hostIds.add(hostId);
      }
      for (final hostId in hostIds) {
        if (stopping.isCompleted) return;
        final kept = await ssh.adoptRunning(hostId);
        if (kept > 0) sink.writeln('ssh: kept $kept session(s) on $hostId');
      }
    }),
  );

  // The conversation index: every conversation a written row names is read
  // from its agent's store, and once per store, what the workspace already
  // had — not in the first moments either.
  data.conversations.start(transcripts);
  unawaited(
    Future<void>.delayed(agentScanDelay).then((_) async {
      if (stopping.isCompleted) return;
      final indexed = await data.conversations.backfill();
      if (indexed > 0) {
        sink.writeln('conversation index: $indexed conversation(s) read');
      }
    }),
  );

  // Asked by platform: SIGINT is the only signal Windows has, and watching
  // SIGTERM there throws errno 50 from `onListen`'s own microtask, where no
  // try/catch around `listen` can see it.
  final subscriptions = <StreamSubscription<void>>[
    server.listen(listener),
    if (until != null) until.asStream().listen((_) => stop(0)),
    ProcessSignal.sigint.watch().listen((_) => stop(0)),
    if (!Platform.isWindows) ...[
      ProcessSignal.sigterm.watch().listen((_) => stop(0)),
      // Ignored on purpose: an SSH channel closing sends this.
      ProcessSignal.sighup.watch().listen((_) {}),
    ],
  ];

  sink
    ..writeln('karmashala_host serving on ${listener.address}')
    ..writeln('server "${settings.name}", data in $dataDirectory')
    ..writeln('pty library ${pty.library}')
    ..writeln(
      hookServer == null
          ? 'agent hooks unavailable — the line above says why'
          : 'agent hooks on port ${hookServer.port}',
    )
    ..writeln(
      mcp == null
          ? 'agent tools unavailable — the line above says why'
          : mcp.serving
          ? 'agent tools on port ${mcp.endpoint.port}'
          : 'agent tools refused — the line above says why',
    )
    ..writeln('store ${p.join(dataDirectory, kStoreFileName)}')
    ..writeln(
      automations == null
          ? 'automations unavailable — the line above says why'
          : 'automations scheduled here',
    )
    ..writeln(
      !companionServing
          ? 'companion unavailable — the line above says why'
          : companion.service == null
          ? 'companion off — remote access is switched off '
                '(companion.enabled in server.json), '
                '${companion.paired()} phone(s) paired'
          : 'companion on port ${companion.port} (bound to ${settings.bind}), '
                '${companion.paired()} phone(s) paired',
    )
    ..writeln(_localRelayLine(companionServing ? companion : null))
    // Said out loud: coming back with nothing and coming back with four dead
    // sessions are different situations.
    ..writeln(
      'restored $remembered session(s) from ${paths.sessionsDirectory}',
    );
  await sink.flush();

  final code = await stopping.future;
  // First: a turn this stop cuts off must stay recorded open.
  for (final subscription in turnFollow) {
    await subscription.cancel();
  }
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await listener.close();
  spools?.close();
  await hookServer?.close();
  await mcp?.close();
  await recordings.close();
  tools.close();
  await companion.close();
  agentWork.stop();
  delivery.stop();
  await git.stop();
  await files.close();
  await sessionTranscripts.close();
  await sessionRecordReadings.close();
  await terminals.dispose();
  await ssh.close();
  storeDesk.close();
  await attention.close();
  await queueEnds.cancel();
  await delegations.close();
  handoffSweep.cancel();
  await handoffDelivery.close();
  await sessionQueue.close();
  await turnSettlement.close();
  await status.close();
  // Before the sessions end: a check the shutdown kills is not a verdict.
  await statusFollow?.cancel();
  await automations?.close();
  // Its links and watchers, before the sessions it hosts end; then the
  // Chrome this server launched (never one it only attached to).
  await flutter.close();
  appDiscovery.close();
  deviceClaims.close();
  await devices.close();
  await browser.close();
  await recording.close();
  await registry.shutdown();
  await sessionSync.close();
  await checkpoints.close();
  data.conversations.close();
  database.close();
  lock.release();
  // Last, so clients still hear every session end, and after the lock, so a
  // client that redials on the hang-up can start the next serve at once.
  // Each is half-closed and waited for: the exit leaves no disconnect
  // pending (Windows only, orderly_close.dart).
  await settleUnixSockets(log: sink.writeln);
  // Bounded: a reader that is there but not reading must not hold the exit.
  await Future.wait([
    sink.flush(),
    errSink.flush(),
  ]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
  return code;
}

List<Object?> _names(List<Map<String, Object?>> schemas) => [
  for (final schema in schemas) schema['name'],
];

/// `--data-dir=<dir>`, absolute, or null when missing or empty.
String? dataDirectoryOf(List<String> args) {
  const flag = '--data-dir=';
  for (final arg in args) {
    if (!arg.startsWith(flag)) continue;
    final value = arg.substring(flag.length).trim();
    if (value.isNotEmpty) return p.absolute(value);
  }
  return null;
}
