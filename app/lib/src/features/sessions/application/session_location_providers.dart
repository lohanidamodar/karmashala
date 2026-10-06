import 'package:agent_cli/process.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneSessionId;
import 'package:karmashala_remote/client.dart' show CompanionPairing;
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';
import '../../files/data/pick_server.dart' show serverDisplayName;
import '../../remote/application/machines_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'session_providers.dart';
import 'session_signals.dart';
import 'session_working_directory.dart';

/// Where a session runs, in the words the sidebar uses for its machines.
class SessionLocation {
  const SessionLocation({
    required this.kind,
    required this.label,
    required this.name,
    this.folder,
  });

  final EnvironmentKind kind;

  /// The short form, for a bar with room for a word: `Windows`,
  /// `WSL · archlinux`, or the server's name when the host is another machine.
  final String label;

  /// The full form: [label], qualified with the server when it is elsewhere.
  final String name;

  /// The directory the agent runs in, as that machine spells it.
  final String? folder;
}

/// Where [environment] is, as this window should name it. On a server
/// elsewhere ([machine] set) its own host is called by the server's name:
/// "Windows" alone would read as the computer in front of you.
SessionLocation? locationOf(
  ExecutionEnvironment environment, {
  CompanionPairing? machine,
  String? folder,
}) {
  final own = environmentLabel(environment) ?? environment.name.trim();
  if (own.isEmpty) return null;
  final server = machine == null ? null : serverDisplayName(machine);
  return SessionLocation(
    kind: environment.kind,
    label: server != null && isLocalHost(environment.kind) ? server : own,
    name: server == null ? own : '$own on $server',
    folder: folder,
  );
}

/// Where [sessionId] runs, or null while its directory or environment row is
/// not known: a name the row does not give would be a guess.
final sessionLocationProvider = Provider.autoDispose
    .family<SessionLocation?, String>((ref, sessionId) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      final row = ref.read(sessionsDataProvider).getById(sessionId);
      if (row == null) return null;
      final directory = sessionWorkingDirectoryOf(ref, row);
      if (directory == null) return null;
      for (final env in ref.watch(environmentsControllerProvider)) {
        if (env.id != directory.environmentId) continue;
        return locationOf(
          env,
          machine: ref.watch(activeMachineProvider),
          folder: directory.path.isEmpty ? null : directory.path,
        );
      }
      return null;
    });

/// Where the session pane [paneId] runs or reads — a chat pane's too — or
/// null for a pane holding no session.
final paneLocationProvider = Provider.autoDispose
    .family<SessionLocation?, String>((ref, paneId) {
      final sessionId =
          chatPaneSessionId(paneId) ?? ref.watch(sessionOfPaneProvider(paneId));
      return sessionId == null
          ? null
          : ref.watch(sessionLocationProvider(sessionId));
    });
