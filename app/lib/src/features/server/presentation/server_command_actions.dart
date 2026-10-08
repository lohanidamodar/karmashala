import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../terminal/application/local_host_providers.dart';
import '../application/server_commands.dart';
import '../application/server_overview.dart';

/// Runs [command] on this machine's server, Restart and Stop confirmed first
/// with what they end. Refuses what the server's overview does not offer.
/// [confirm] false acts at once: the tray's Restart and Stop are already the
/// person's word, and its window may be hidden behind the confirm.
///
/// [context] must outlive the call: quick open passes its navigator's, since
/// its own route is gone before the confirm is answered.
Future<void> runServerCommand(
  BuildContext context,
  ServerCommand command, {
  bool confirm = true,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final ServerOverview overview;
  try {
    overview = await container.read(serverOverviewProvider.future);
  } on Object {
    return;
  }
  if (!context.mounted || !serverCommandsFor(overview).contains(command)) {
    return;
  }
  switch (command) {
    case ServerCommand.start:
      await container.read(localHostStatusProvider.notifier).start();
      container.invalidate(serverOverviewProvider);
    case ServerCommand.restart when !confirm:
      await _restart(container, overview);
    case ServerCommand.restart:
      await confirmServerRestart(context, overview);
    case ServerCommand.stop when !confirm:
      await _stop(container, overview);
    case ServerCommand.stop:
      await confirmServerStop(context, overview);
  }
}

/// Asks before restarting, naming the sessions it ends, then restarts.
Future<void> confirmServerRestart(
  BuildContext context,
  ServerOverview overview,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final live = overview.liveSessions;
  final continues = container
      .read(settingsControllerProvider)
      .continueInterruptedTurns;
  final message = switch (live) {
    null =>
      'The server would not say what it holds. Restarting it ends every '
          'session it is running; their panes keep what they showed, but '
          'the processes stop.',
    0 =>
      'It runs no sessions, so nothing ends. This window reconnects when '
          'it is back.',
    _ =>
      'This ends the ${_sessions(live)} it holds: their panes keep what '
          'they showed, but the processes stop and are not reattached.',
  };
  final confirmed = await showConfirmDialog(
    context,
    title: 'Restart the server?',
    message: live != 0 && continues
        ? '$message An agent turn it cuts off is continued once it is '
              'back.'
        : message,
    confirmLabel: 'Restart',
    destructive: live != 0,
  );
  if (!confirmed) return;
  await _restart(container, overview);
}

/// Restarts the server, forcing it when it holds sessions (or will not say).
Future<void> _restart(
  ProviderContainer container,
  ServerOverview overview,
) async {
  await container
      .read(localHostStatusProvider.notifier)
      .restart(force: overview.liveSessions != 0);
  container.invalidate(serverOverviewProvider);
}

/// Asks before stopping, naming the sessions it ends, then stops.
Future<void> confirmServerStop(
  BuildContext context,
  ServerOverview overview,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final live = overview.liveSessions;
  final message = switch (live) {
    null =>
      'The server would not say what it holds. Stopping it ends every '
          'session it is running, and nothing starts it again until you '
          'press Start.',
    0 =>
      'It runs no sessions, so nothing ends. Nothing starts it again until '
          'you press Start, and this window has no data until then.',
    _ =>
      'This ends the ${_sessions(live)} it holds, and nothing starts it '
          'again until you press Start. This window has no data until then.',
  };
  final confirmed = await showConfirmDialog(
    context,
    title: 'Stop the server?',
    message: message,
    confirmLabel: 'Stop',
    destructive: true,
  );
  if (!confirmed) return;
  await _stop(container, overview);
}

/// Stops the server, forcing it when it holds sessions (or will not say).
Future<void> _stop(ProviderContainer container, ServerOverview overview) async {
  await container
      .read(localHostStatusProvider.notifier)
      .stop(force: overview.liveSessions != 0);
  container.invalidate(serverOverviewProvider);
}

String _sessions(int count) =>
    count == 1 ? '1 running session' : '$count running sessions';

/// Runs what the tray asks of the server, in the widget that calls it from
/// `build` — the shell, which holds the navigator a confirm needs.
void listenForServerCommandRequests(BuildContext context, WidgetRef ref) {
  ref.listen(serverCommandRequestProvider, (_, request) {
    if (request == null || !context.mounted) return;
    final command = request.command;
    if (command == null) {
      openSettingsTab(ref, anchor: SettingsAnchor.serverStatus);
    } else {
      unawaited(runServerCommand(context, command, confirm: false));
    }
  });
}
