import 'dart:async';
import 'dart:io';

import 'package:agent_cli/stream.dart'
    show kToolImageFolderName, useToolImageDirectory;
import 'package:karmashala_ui/transcript.dart' show installMessageBoundaries;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'package:karmashala_local_ipc/karmashala_local_ipc.dart'
    show exitAfterSocketsSettle;
import 'package:karmashala_remote/client.dart' show CompanionPairing;

import 'src/app/bootstrap_failure_app.dart';
import 'src/app/karmashala_app.dart';
import 'src/app/server_session_root.dart';
import 'src/core/capabilities/device_name.dart';
import 'src/core/capabilities/capabilities.dart';
import 'src/core/lifecycle/app_binding.dart';
import 'src/core/lifecycle/app_lifecycle.dart';
import 'src/core/lifecycle/keyboard_focus_keeper.dart';
import 'src/core/lifecycle/link_lifecycle.dart';
import 'src/core/lifecycle/relaunch.dart';
import 'src/core/lifecycle/server_session.dart';
import 'src/core/lifecycle/server_switcher.dart';
import 'src/core/lifecycle/uncaught_errors.dart';
import 'package:karmashala_core/logging.dart';
import 'src/core/logging/diagnostics_bootstrap.dart';
import 'src/core/paths/app_support_directory.dart';
import 'src/core/paths/server_data_directory.dart';
import 'src/core/probe/probe_mode.dart';
import 'src/core/server/companion_migration.dart';
import 'src/core/server/machines.dart';
import 'src/core/server/network_changes.dart';
import 'src/core/server/secure_machine_store.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/verification/application/verification_providers.dart';

/// Application entry point. Logging and the uncaught-error handlers first, so
/// whatever the bootstrap does next is on record if it fails.
Future<void> main() async {
  ensureAppBinding();
  AppLogger.initialize();
  final logger = AppLogger.named('bootstrap');
  UncaughtErrorHandlers(logger).install();
  // A chat message that cannot be drawn shrinks to a line, not a blank pane.
  installMessageBoundaries();

  try {
    await _bootstrap(logger);
  } catch (error, stack) {
    logger.error('Bootstrap failed.', error, stack);
    await Diagnostics.instance.flushFile();
    runApp(
      BootstrapFailureApp(
        error: error,
        stack: stack,
        logDirectory: await _logDirectoryOrNull(),
      ),
    );
  }
}

Future<Directory?> _logDirectoryOrNull() async {
  try {
    return await defaultLogDirectory();
  } catch (_) {
    return null;
  }
}

/// The process's part of start-up — MediaKit, logging, the machines store,
/// the window and the OS integration — around the one per-server part,
/// [ServerSession.open]. A switch of server closes that session and opens
/// the next in this process ([ServerSwitcher], plan step 14).
Future<void> _bootstrap(AppLogger logger) async {
  // What this client can do, measured once and handed to every session.
  final client = await ClientCapabilities.measureNamed(readDeviceModel);
  // Loads libmpv, which decodes the device pane's H.264 live view.
  if (client.mediaPlayback) MediaKit.ensureInitialized();

  // Which build, on what OS — first line of the buffer, so it is the first line
  // of anything copied out. A log that cannot say its version answers nothing.
  logger.info('Starting ${buildIdentity()}');
  // Read once and handed to the container below, so every side-effect site
  // asks one provider. A probe without its own data folder is refused here,
  // before the log file is opened.
  final probe = ProbeMode.current;
  if (probe.enabled) {
    logger.info(
      'PROBE instance; data folder ${probe.dataDirectory ?? '(none)'}. '
      'Disabled: ${ProbeMode.disabledEffects.join(', ')}.',
    );
    await appSupportDirectory();
    await serverDataDirectory();
  }
  // Opening the file needs `path_provider`, hundreds of milliseconds in, so it
  // backfills the buffer. Awaited: the directory below asks the same question.
  await attachDefaultLogFile(Diagnostics.instance);
  // Transcripts read here spill their images where this machine's server
  // keeps and sweeps them.
  if (client.hostsServer) {
    try {
      final data = await serverDataDirectory();
      useToolImageDirectory(p.join(data.path, kToolImageFolderName));
    } catch (error) {
      logger.info('Tool images stay in the temp folder: $error');
    }
  }
  // Which server this window is a client of (slice 5e): this machine's own,
  // or one elsewhere chosen in Settings → Machines, only dialled.
  final support = await appSupportDirectory();
  // A client that cannot host keeps its machines, device keys and all, in
  // the keystore-backed store the companion already paired into.
  final machines = Machines(
    client.hostsServer
        ? MachinesFileStore.inDirectory(support.path)
        : SecureCompanionStore(onLog: logger.info),
  );
  // A phone build installed over the companion opens the companion's machine.
  if (!client.hostsServer) {
    await adoptCompanionPairing(machines, logger: logger);
  }
  final remote = await machines.active();
  SharedHostLinks.clientName = client.deviceName;

  // The verification artifact root, before the first frame: a Riverpod provider
  // that threw stays errored for the life of the process. Best-effort.
  // This machine's own data folder, whichever server is in use.
  try {
    await resolveVerificationRoot();
  } catch (error, stack) {
    logger.warning('Verification artifact root unavailable.', error, stack);
  }
  // The agents' status hooks and the rest run **after the first frame**
  // rather than before the window. The gate's timeout is load-bearing: a tray
  // launch may never paint. A switch of server waits on the same gate for the
  // old tree to go.
  Future<void> afterFirstFrame() => WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );

  // Switching servers closes one session and opens the next in this process
  // (plan step 14); every session's container is handed the switcher.
  late final AppLifecycle lifecycle;
  late final ServerSwitcher switcher;
  // A phone's link follows the app into the background and back, and across
  // network changes. A desktop window is never put in the background.
  final links = client.systemIntegration
      ? null
      : LinkLifecycle(networkChanges: networkChanges(onLog: logger.info));
  Future<ServerSession> openSession(CompanionPairing? remote) async {
    final session = await ServerSession.open(
      remote: remote,
      machines: machines,
      probe: probe,
      support: support,
      logger: logger,
      client: client,
      overrides: [serverSwitcherProvider.overrideWithValue(switcher)],
    );
    links?.adopt(session);
    return session;
  }

  Future<void> quit() async {
    final system = lifecycle.systemIntegration;
    if (system != null) return system.quit();
    await lifecycle.shutdown();
    await exitAfterSocketsSettle(0, log: logger.info);
  }

  switcher = ServerSwitcher(
    open: openSession,
    machines: machines,
    nextFrame: afterFirstFrame,
    quit: quit,
    // The fallback when the old session will not close: start afresh, as
    // every switch did before. Only where the app can restart itself.
    relaunch: client.relaunch
        ? () async {
            await relaunchAfterExit();
            await quit();
          }
        : null,
    onOpened: client.systemIntegration
        ? (remote) => unawaited(_retitleWindow(probe, remote, logger))
        : null,
    hostsServer: client.hostsServer,
    logger: logger,
  );

  links?.attach();
  // A desktop window loses focus to other apps; the keyboard must come back
  // with it before the first key, not after (see the class).
  if (client.systemIntegration) KeyboardFocusKeeper.install();

  // A client with no server of its own and no machine chosen opens nothing:
  // the root shows pairing, and the pairing's switch opens the first session.
  if (remote == null && !client.hostsServer) {
    logger.info('No machine chosen and none to host; showing pairing.');
    lifecycle = AppLifecycle.withoutSession(logger: logger);
    switcher.startWithoutServer(lifecycle: lifecycle);
    lifecycle.startMemoryCensus();
    runApp(
      ServerSessionRoot(
        switcher: switcher,
        app: const KarmashalaApp(),
        client: client,
      ),
    );
    installServerSessionStatics();
    return;
  }

  // Everything that belongs to that server: the layout store, the access, the
  // data connection, the container and the start-up acts that need them.
  final session = await openSession(remote);
  final container = session.container;

  // One owner for everything below, so quitting is an ordered teardown rather
  // than a process that happens to end. See `AppLifecycle`.
  lifecycle = AppLifecycle(container, session: session, logger: logger);
  switcher.start(session, remote: remote, lifecycle: lifecycle);

  // A release build has no VM service, so the log is the only place this app
  // can say what it is holding. Started here rather than after the first frame:
  // the interval is long enough that bootstrap is over before it first fires.
  lifecycle.startMemoryCensus();

  // Desktop OS integration: window/tray/keep-awake/launch-at-login.
  if (client.systemIntegration) {
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
        title: _windowTitle(probe, remote),
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (error, stack) {
      logger.warning('Window manager init failed.', error, stack);
    }
    await lifecycle.startSystemIntegration();
  }

  // The root holds the open session's container, and swaps it on a switch.
  runApp(
    ServerSessionRoot(
      switcher: switcher,
      app: const KarmashalaApp(),
      client: client,
    ),
  );

  session.startAfterRunApp(lifecycle, afterFirstFrame: afterFirstFrame);

  // The statics `karmashala_ui` reads — Browse's sources, which dialog opens,
  // hidden files — installed once, each reading the current session per call.
  installServerSessionStatics();
}

/// The window's title: the app, a probe said so, and a server elsewhere named.
String _windowTitle(ProbeMode probe, CompanionPairing? remote) {
  final app = probe.enabled ? 'Karmashala — PROBE' : 'Karmashala';
  return remote == null ? app : '$app — ${serverNameForSwitch(remote)}';
}

/// Names the server a switch opened in the title bar.
Future<void> _retitleWindow(
  ProbeMode probe,
  CompanionPairing? remote,
  AppLogger logger,
) async {
  try {
    await windowManager.setTitle(_windowTitle(probe, remote));
  } on Object catch (error) {
    logger.warning('Setting the window title failed: $error');
  }
}
