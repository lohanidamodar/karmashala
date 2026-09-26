import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';

import '../agents/application/agent_hook_sweep.dart';
import '../agents/application/host_hook_endpoint.dart';
import 'control_server_status.dart';
import 'launcher_control_server.dart';

/// The control server this run started, so Settings can act on the one that is
/// actually up. Null in every test and every run that never started one.
class ControlServerHandle extends Notifier<LauncherControlServer?> {
  @override
  LauncherControlServer? build() => null;

  void set(LauncherControlServer? server) => state = server;
}

final controlServerHandleProvider =
    NotifierProvider<ControlServerHandle, LauncherControlServer?>(
      ControlServerHandle.new,
    );

/// What a restart did, in the words the settings row shows.
class ControlServerRestart {
  const ControlServerRestart({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// Whether a restart is in flight, so the button can refuse to be pressed
/// twice — a second stop half way through the first start is how a port ends
/// up held by nothing.
class ControlServerRestarting extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final controlServerRestartingProvider =
    NotifierProvider<ControlServerRestarting, bool>(
      ControlServerRestarting.new,
    );

/// **Rebinds this app's own control server**, and rewrites the agent hook
/// configs that carry its token.
///
/// The token is minted fresh by `start()`, so a restart that skipped the sweep
/// would leave every agent posting the old one — hooks would keep firing and
/// nothing would arrive, which is worse than the failure being restarted from.
///
/// Started with no arguments, exactly as bootstrap does: a second spelling of
/// those defaults is how a restarted server comes up differently from the one
/// the app launched with.
Future<ControlServerRestart> restartControlServer(
  ProviderContainer container, {
  AppLogger? logger,
}) async {
  // Asked first, and before anything else can return: a second stop half way
  // through the first start is how a port ends up held by nothing.
  if (container.read(controlServerRestartingProvider)) {
    return const ControlServerRestart(
      ok: false,
      message: 'A restart is already running.',
    );
  }
  final server = container.read(controlServerHandleProvider);
  if (server == null) {
    return const ControlServerRestart(
      ok: false,
      message:
          'This run never started a control server, so there is none to '
          'restart. Reopening the app is what starts one.',
    );
  }
  final restarting = container.read(controlServerRestartingProvider.notifier);
  restarting.set(true);
  try {
    // Safe on a server that never bound, which is the "start it again" case.
    await server.stop();
    await server.start();
    final status = container.read(controlServerStatusProvider);
    final endpoint = installableHookEndpoint(
      container,
      appRoute: server.hookEndpoint,
    );
    if (endpoint == null) {
      return ControlServerRestart(
        ok: false,
        message:
            'The server came back without a hook endpoint, so no agent '
            'was rewritten. ${status.message}',
      );
    }
    final report = await sweepAgentHooks(container, endpoint, logger: logger);
    final rewritten = report == null
        ? 'no agent config could be rewritten'
        : '${report.installed} agent config'
              '${report.installed == 1 ? '' : 's'} rewritten with the new token';
    return ControlServerRestart(
      ok: !status.failedClosed,
      message: status.failedClosed
          ? '${status.message} ($rewritten)'
          : 'The control server is back, and $rewritten. An agent already '
                'running reads its config on its next callback.',
    );
  } on Object catch (error) {
    return ControlServerRestart(ok: false, message: 'Restart failed: $error');
  } finally {
    restarting.set(false);
  }
}
