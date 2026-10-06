import 'package:riverpod/riverpod.dart';

import 'server_overview.dart';

/// What quick open and the tray can do to this machine's server. Each runs
/// the Settings → Server page's own action, confirm included.
enum ServerCommand {
  start('Start server'),
  restart('Restart server'),
  stop('Stop server');

  const ServerCommand(this.label);
  final String label;
}

/// The commands [overview]'s server takes now, in that order; none while this
/// app is not the one running it, or before it has been read.
List<ServerCommand> serverCommandsFor(ServerOverview? overview) {
  if (overview == null || overview.controlsRefusal != null) return const [];
  return [
    if (overview.canStart) ServerCommand.start,
    if (overview.canRestart) ServerCommand.restart,
    if (overview.canStop) ServerCommand.stop,
  ];
}

/// "Server: running · 3 sessions", the tray's line for [overview].
String describeServerLine(ServerOverview? overview) {
  if (overview == null) return 'Server: not read yet';
  if (overview.usesAnotherMachine) return 'Server: on another machine';
  final state = overview.state.label.toLowerCase();
  final live = overview.liveSessions;
  if (overview.state != ServerRunState.running || live == null || live == 0) {
    return 'Server: $state';
  }
  return 'Server: $state · $live ${live == 1 ? 'session' : 'sessions'}';
}

/// What the tray asked the shell to do; [serial] makes a repeat a change.
typedef ServerCommandRequest = ({ServerCommand? command, int serial});

/// A server command asked for outside the widget tree — the tray — for the
/// shell, which holds the navigator its confirm needs. A null command opens
/// Settings → Server.
class ServerCommandRequests extends Notifier<ServerCommandRequest?> {
  @override
  ServerCommandRequest? build() => null;

  void ask(ServerCommand command) =>
      state = (command: command, serial: (state?.serial ?? 0) + 1);

  void openSettings() =>
      state = (command: null, serial: (state?.serial ?? 0) + 1);
}

final serverCommandRequestProvider =
    NotifierProvider<ServerCommandRequests, ServerCommandRequest?>(
      ServerCommandRequests.new,
    );
