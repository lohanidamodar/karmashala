import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/bootstrap_failure_app.dart';
import 'src/app/karmashala_app.dart';
import 'src/app/companion/companion_bootstrap.dart';
import 'src/app/companion/companion_mode.dart';
import 'src/core/capabilities/capabilities.dart';
import 'src/core/lifecycle/app_binding.dart';
import 'src/core/lifecycle/app_lifecycle.dart';
import 'src/core/lifecycle/server_session.dart';
import 'src/core/lifecycle/uncaught_errors.dart';
import 'package:karmashala_core/logging.dart';
import 'src/core/logging/diagnostics_bootstrap.dart';
import 'src/core/paths/app_support_directory.dart';
import 'src/core/paths/server_data_directory.dart';
import 'src/core/probe/probe_mode.dart';
import 'src/core/server/machines.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/verification/application/verification_providers.dart';

/// Application entry point. Logging and the uncaught-error handlers first, so
/// whatever the bootstrap does next is on record if it fails.
Future<void> main() async {
  // A companion build boots its own shell and nothing below this line — no
  // PTYs, no discovery, no control server, no tray, no window chrome.
  if (CompanionMode.enabled) return runCompanionApp();

  ensureAppBinding();
  // A desktop bootstrap on a phone is a build mistake, and it used to be a
  // silent one: an APK that installed, launched and sat on a black screen.
  if (Platform.isAndroid || Platform.isIOS) {
    throw StateError(
      'This is the desktop build running on a phone. Build the companion with '
      '--dart-define=KARMASHALA_MODE=companion.',
    );
  }
  AppLogger.initialize();
  final logger = AppLogger.named('bootstrap');
  UncaughtErrorHandlers(logger).install();

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
/// [ServerSession.open]. A server switch relaunches the process (step 14
/// will switch in process), so the session opened here lasts until quit.
Future<void> _bootstrap(AppLogger logger) async {
  // Loads libmpv, which decodes the device pane's H.264 live view.
  MediaKit.ensureInitialized();

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
  // Which server this window is a client of (slice 5e): this machine's own,
  // or one elsewhere chosen in Settings → Machines, only dialled.
  final support = await appSupportDirectory();
  final machines = Machines(MachinesFileStore.inDirectory(support.path));
  final remote = await machines.active();
  SharedHostLinks.clientName = _machineName();

  // The verification artifact root, before the first frame: a Riverpod provider
  // that threw stays errored for the life of the process. Best-effort.
  // This machine's own data folder, whichever server is in use.
  try {
    await resolveVerificationRoot();
  } catch (error, stack) {
    logger.warning('Verification artifact root unavailable.', error, stack);
  }
  // Everything that belongs to that server: the layout store, the access, the
  // data connection, the container and the start-up acts that need them.
  final session = await ServerSession.open(
    remote: remote,
    machines: machines,
    probe: probe,
    support: support,
    logger: logger,
  );
  final container = session.container;
  final capabilities = container.read(capabilitiesProvider);

  // One owner for everything below, so quitting is an ordered teardown rather
  // than a process that happens to end. See `AppLifecycle`.
  final lifecycle = AppLifecycle(container, session: session, logger: logger);

  // A release build has no VM service, so the log is the only place this app
  // can say what it is holding. Started here rather than after the first frame:
  // the interval is long enough that bootstrap is over before it first fires.
  lifecycle.startMemoryCensus();

  // Desktop OS integration: window/tray/keep-awake/launch-at-login.
  if (capabilities.systemIntegration) {
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
        title: probe.enabled ? 'Karmashala — PROBE' : 'Karmashala',
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

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KarmashalaApp(),
    ),
  );

  // The agents' status hooks and the rest run **after the first frame**
  // rather than before the window. The gate's timeout is load-bearing: a tray
  // launch may never paint.
  Future<void> afterFirstFrame() => WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );
  session.startAfterRunApp(lifecycle, afterFirstFrame: afterFirstFrame);

  // The statics `karmashala_ui` reads — Browse's sources, which dialog opens,
  // hidden files — installed once, each reading the current session per call.
  installServerSessionStatics();
}

/// What this client is called at a server: the machine's name.
String _machineName() {
  final name = Platform.localHostname.trim();
  return name.isEmpty ? 'karmashala' : name;
}
