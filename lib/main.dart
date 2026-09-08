import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/karmashala_app.dart';
import 'src/app/companion/companion_bootstrap.dart';
import 'src/app/companion/companion_mode.dart';
import 'src/core/database/app_database.dart';
import 'src/core/database/database_providers.dart';
import 'src/core/lifecycle/app_lifecycle.dart';
import 'src/core/logging/app_logger.dart';
import 'src/core/logging/build_identity.dart';
import 'src/core/logging/diagnostics.dart';
import 'src/core/logging/diagnostics_bootstrap.dart';
import 'src/core/process/local_command_runner.dart';
import 'src/core/util/clock.dart';
import 'src/features/agents/application/agent_installations_controller.dart';
import 'src/features/environments/application/local_environment_bootstrap.dart';
import 'src/features/environments/data/environment_discovery_service.dart';
import 'src/features/env_secrets/application/env_secrets_controller.dart';
import 'src/features/env_secrets/data/env_vault.dart';
import 'src/features/environments/data/execution_environment_dao.dart';
import 'src/features/mcp/launcher_control_server.dart';
import 'src/features/sessions/application/session_liveness_reconciler.dart';
import 'src/features/sessions/data/session_dao.dart';
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/system/system_integration_service.dart';
import 'src/features/verification/application/verification_providers.dart';

/// Application entry point.
///
/// Bootstraps cross-cutting infrastructure (logging, database) before running
/// the app, then injects the opened database into the provider graph via a
/// `ProviderScope` override so features depend on providers, not globals.
Future<void> main() async {
  // A companion build (`--dart-define=KARMASHALA_MODE=companion`) boots its
  // own shell and nothing below this line — no PTYs, no discovery, no control
  // server, no tray, no window chrome.
  if (CompanionMode.enabled) return runCompanionApp();

  WidgetsFlutterBinding.ensureInitialized();
  // A desktop bootstrap on a phone is a build mistake, and it used to be a
  // *silent* one: `flutter build apk` without
  // `--dart-define=KARMASHALA_MODE=companion` produced an APK that installed,
  // launched, failed to load libmpv — which ships only for Windows here — and
  // then sat on a black screen with nothing in the log but the media_kit
  // complaint. Nothing below this line makes sense on a phone anyway: PTYs, a
  // control server, a tray icon, window chrome.
  if (Platform.isAndroid || Platform.isIOS) {
    throw StateError(
      'This is the desktop build running on a phone. Build the companion with '
      '--dart-define=KARMASHALA_MODE=companion.',
    );
  }
  // Loads libmpv, which decodes the device pane's H.264 live view.
  MediaKit.ensureInitialized();
  AppLogger.initialize();
  final logger = AppLogger.named('bootstrap');

  // Which build, on what OS — the first line of the buffer, so it is the first
  // line of the file and of anything copied out of the panel. A log that does
  // not say which version wrote it cannot answer whether the fix under
  // discussion was even present.
  logger.info('Starting ${buildIdentity()}');
  // Opening the file needs `path_provider`, which is hundreds of milliseconds
  // into the launch — so it backfills the buffer rather than starting blank,
  // and the launch does not wait for it.
  // Awaited, not fired and forgotten: `AppDatabase.open()` on the next line
  // asks `path_provider` the same question, so this costs nothing, and it means
  // the file is open before anything interesting has had a chance to fail.
  await attachDefaultLogFile(Diagnostics.instance);
  final database = await AppDatabase.open();
  bootstrapMetadata(database, logger: logger);

  // Nothing this process started is running yet, so no row may still claim to
  // be. Rows only ever moved *into* `running`, so before this every session
  // that was open when the app last closed went on drawing a play glyph in the
  // Explorer for ever — and went on being subscribed to, and kept the CLI-store
  // sweep permanently armed. Here rather than in a provider because it is a
  // statement about the process: there are no panes at all at this point, which
  // is what makes it true. See `SessionLivenessReconciler`.
  final lost = markSessionsLostOnLaunch(SessionDao(database));
  if (lost > 0) {
    logger.info('$lost session(s) were still marked live from a previous run.');
  }

  // The verification artifact root, before the first frame. `path_provider` has
  // already been asked twice above, so this costs a `mkdir`.
  //
  // Awaited here because `verificationRootProvider` throws until it is, and a
  // Riverpod provider that threw stays errored for the life of the process: one
  // surface reading it a frame too early used to break the verification pane and
  // every MCP verification tool until the app was restarted. Best-effort — a
  // root that cannot be created is a feature that says so when it is opened,
  // not a launch that fails.
  try {
    await resolveVerificationRoot();
  } catch (error, stack) {
    logger.warning('Verification artifact root unavailable.', error, stack);
  }

  // Ensure the Windows environment exists immediately, then discover and persist
  // all execution environments (Windows host + installed WSL distributions),
  // best-effort — discovery degrades to Windows-only if WSL is unavailable.
  const clock = SystemClock();
  final environmentDao = ExecutionEnvironmentDao(database);
  ensureLocalEnvironment(environmentDao, clock);
  final discovered = await EnvironmentDiscoveryService(
    host: const LocalCommandRunner(),
    clock: clock,
    logger: logger,
  ).discover();
  for (final env in discovered) {
    environmentDao.upsert(env);
  }
  logger.info('Discovered ${discovered.length} execution environment(s).');

  // The user's environment variables, from a folder restricted to this
  // account. Awaited rather than fired off, because `restoreLivePanes` can
  // re-launch panes as soon as the container exists and a pane that started
  // half a second before its variables loaded would silently lack them.
  // Reading is one small file; `load()` never throws, so a vault that cannot be
  // opened costs an empty overlay and a banner in settings, not a failed
  // launch.
  final envVault = await EnvVault.open(logger: logger);
  await envVault.load();

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      envVaultProvider.overrideWithValue(envVault),
    ],
  );

  // The persisted diagnostics preferences: debug mode's root level, the buffer
  // bound, and whether the file is written at all.
  container.read(settingsControllerProvider.notifier).applyDiagnostics();

  // Built eagerly for one reason: constructing it installs the redaction rule
  // that keeps this session's secret values out of the log. Waiting for the
  // first pane to build it lazily would leave a window in which a value could
  // reach the log file unredacted.
  container.read(envSecretsControllerProvider);

  // First run (or if it has never completed): probe every environment for
  // installed agents once, in the background so it doesn't delay window show.
  // The controller's state updates when it finishes, so the UI fills in live.
  if (database.readMetadata(MetadataKeys.agentsDiscoveredAt) == null) {
    unawaited(_discoverAgentsOnFirstRun(container, database, clock, logger));
  }

  // One owner for everything below, so quitting is an ordered teardown rather
  // than a process that happens to end. See `AppLifecycle`.
  final lifecycle = AppLifecycle(container, logger: logger);

  // An already-discovered workspace still has to notice agents it has never
  // looked for — the ones an app upgrade added to the registry after the
  // one-time scan above had already run.
  lifecycle.startAgentDiscovery();

  // The control server, retained here so the hook sweep below can be started
  // *after* `runApp` — see the sweep's own comment for why that ordering is the
  // point rather than a tidy-up.
  LauncherControlServer? controlServer;

  // Desktop OS integration: window/tray/keep-awake/launch-at-login.
  if (SystemIntegrationService.isSupported) {
    try {
      await windowManager.ensureInitialized();
      final settings = container.read(settingsControllerProvider);
      final restoredSize =
          (settings.windowWidth != null && settings.windowHeight != null)
          ? Size(settings.windowWidth!, settings.windowHeight!)
          : const Size(1200, 800);
      final windowOptions = WindowOptions(
        size: restoredSize,
        minimumSize: const Size(720, 560),
        center: true,
        title: 'Karmashala',
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (error, stack) {
      logger.warning('Window manager init failed.', error, stack);
    }
    await lifecycle.startSystemIntegration();

    // Local control server for the launcher agent's MCP bridge (best-effort).
    //
    // The lifecycle owner keeps the instance — it owns `/agent-hook`'s
    // ephemeral port and token, which the agents' installed hooks have to be
    // told about, and its `stop()` is what removes the handshake on the way
    // out. Nothing installed the hooks before Loop 31: `AgentHookInstaller` had
    // no call site since Loop 28, so `awaitingApproval` and `failed`, which
    // only a hook can observe, were unreachable in the running app.
    controlServer = await lifecycle.startControlServer();
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KarmashalaApp(),
    ),
  );

  // The agents' status hooks, **after the first frame** rather than before the
  // window.
  //
  // This used to run just above `runApp`, and it was 1053 ms of a 1.91 s launch
  // on the owner's machine — 55% of it — because every file operation on the
  // install path was synchronous and several of those paths are
  // `\\wsl.localhost` UNC paths served by a plan9 daemon inside a
  // distribution. "Unawaited" bought nothing: synchronous I/O holds the isolate
  // whether or not anybody is waiting on the future, and the isolate is the
  // thread the first frame is painted on. The I/O is asynchronous now
  // (`AgentHookInstaller`), and this ordering is the other half — the window
  // exists before the app starts rewriting other applications' config files.
  //
  // **The timeout on the gate is load-bearing, not defensive.** `endOfFrame`
  // schedules a frame when the scheduler is idle, but a launch that starts
  // minimised to the tray — which this app supports — may never be asked to
  // paint one, and a sweep that never runs is a run with no status callbacks at
  // all. Two seconds later it goes ahead regardless.
  //
  // What a session started in that window gets is documented on
  // `AppLifecycle.installAgentHooks`: the config entry is a constant already on
  // disk, and the script reads the endpoint file when a hook *fires*, so such a
  // session loses only the events inside the gap rather than its whole
  // lifetime. Until the sweep reports, Settings says the callbacks are not in
  // place yet rather than saying nothing.
  Future<void> afterFirstFrame() => WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );

  if (controlServer != null) {
    lifecycle.installAgentHooks(controlServer, afterFirstFrame: afterFirstFrame);
  }

  // The CLI stores, **once**, behind the same gate and for the same reason.
  //
  // This import used to run on every project expand and every project
  // selection — a full walk of every store each time, on the isolate that
  // draws, with the Explorer's spinner up throughout. It runs here instead, and
  // the project row's "Refresh CLI sessions" is what re-runs it.
  //
  // Not gated on `controlServer`, unlike the hooks: finding conversations an
  // agent already wrote needs nothing bound.
  unawaited(lifecycle.importCliSessions(afterFirstFrame: afterFirstFrame));

  // The stored agent executables, **behind the same gate and on every launch**.
  //
  // A path is durable state; whether it still resolves is a measurement, and
  // the app used to take that measurement once — at the workspace's first scan
  // — and then trust it forever. Codex's self-update turned the path this app
  // had stored into a junction chain Windows refuses to traverse, and every
  // launch afterwards tried to spawn it again. A workspace with nothing wrong
  // pays one `existsSync` per local installation and spawns no processes at
  // all, which is why this can afford to run every time.
  unawaited(lifecycle.repairAgentPaths(afterFirstFrame: afterFirstFrame));

  // And what those executables *are*, when the last reading has aged out.
  //
  // A path is state whose resolution is a measurement; a version is nothing but
  // a measurement, and these CLIs self-update — Codex went 0.145.0 to 0.153.4
  // mid-session. Nothing re-read it: `discoverUnprobed` skips any pair that
  // already has a row, so the number the first scan wrote stood until somebody
  // pressed "Detect agents". This runs after the path check and re-reads only
  // the rows whose recorded reading is older than `kVersionReadingFreshFor`, so
  // a launch with fresh readings spawns nothing here either.
  unawaited(lifecycle.refreshAgentVersions(afterFirstFrame: afterFirstFrame));
}

/// Runs the one-time startup agent discovery. On success it stamps
/// [MetadataKeys.agentsDiscoveredAt] so it never repeats; on failure it leaves
/// the flag unset so the next launch retries.
Future<void> _discoverAgentsOnFirstRun(
  ProviderContainer container,
  AppDatabase database,
  Clock clock,
  AppLogger logger,
) async {
  try {
    final report = await container
        .read(agentInstallationsControllerProvider.notifier)
        .discoverAll();
    database.writeMetadata(
      MetadataKeys.agentsDiscoveredAt,
      clock.nowUtc().toIso8601String(),
    );
    // The whole sentence, not just the hit count. A first run that found three
    // agents in WSL and none on Windows used to log "found 3 agent(s)", which
    // reads as a clean result and hid the fact that the Windows probe had come
    // back empty and would never be repeated.
    logger.info('First-run agent discovery: ${report.summary}');
  } catch (error, stack) {
    logger.warning(
      'First-run agent discovery failed; will retry next launch.',
      error,
      stack,
    );
  }
}
