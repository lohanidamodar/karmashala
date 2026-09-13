import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_working_directory.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'environment_terminals_providers.dart';
import 'session_context.dart';

/// **Where the thing you are looking at is working, now.**
///
/// Three readings, decreasing liveness:
///
/// 1. what an agent's **hook** last said — the only live reading for an agent
///    pane, which paints a TUI and emits no OSC 7;
/// 2. what the **pane** last said — OSC 7, so a shell that `cd`s reports it;
/// 3. what the session **recorded** at launch, which is where it started and
///    may be nowhere near where it is.
///
/// Null when none of the three answered. A caller holds its last selection
/// then rather than moving somewhere it cannot name (§19).
EnvironmentPath? whereYouAre({
  EnvironmentPath? agentReported,
  EnvironmentPath? paneReported,
  EnvironmentPath? recorded,
}) => agentReported ?? paneReported ?? recorded;

/// What an agent's hooks last said about where it is working, by **our**
/// session id.
///
/// In memory on purpose. A hook fires twice per tool call, so persisting this
/// would be a write per tool; and `sessions.working_directory` means "where it
/// was launched", which a resume still needs to be true.
class AgentWorkingDirectories extends Notifier<Map<String, EnvironmentPath>> {
  @override
  Map<String, EnvironmentPath> build() => const {};

  /// Records [directory] for [sessionId]. A repeat of what we already hold is
  /// dropped, so a hook per tool call does not rebuild anything watching this.
  void record(String sessionId, EnvironmentPath directory) {
    final held = state[sessionId];
    if (held != null &&
        held.environmentId == directory.environmentId &&
        held.path == directory.path) {
      return;
    }
    state = {...state, sessionId: directory};
  }

  void forget(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    state = {
      for (final entry in state.entries)
        if (entry.key != sessionId) entry.key: entry.value,
    };
  }
}

final agentWorkingDirectoriesProvider =
    NotifierProvider<AgentWorkingDirectories, Map<String, EnvironmentPath>>(
      AgentWorkingDirectories.new,
    );

/// The directory the pane on screen is in, by the pane's own environment.
///
/// A path is meaningless without the machine it is spelled for, and an
/// `agent:` pane's profile does not name one — its session does, which is what
/// [focusedDirectoryProvider] falls back to.
EnvironmentPath? paneDirectory(Ref ref, String paneId) {
  // This one pane's directory, never the whole state: watching the state made
  // the follower re-run on any pane's liveness or title moving, which is the
  // cost `activePaneSessionIdProvider` documents beside itself.
  final path = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.directoryOf(paneId)),
  );
  if (path == null || path.isEmpty) return null;
  final instance = ref
      .read(terminalSessionsControllerProvider.notifier)
      .instanceFor(paneId);
  if (instance == null) return null;
  final environmentId = environmentIdOfProfile(
    instance.profileId,
    localId: ref.watch(localEnvironmentProvider)?.id,
  );
  if (environmentId == null) return null;
  return EnvironmentPath(environmentId: environmentId, path: path);
}

/// **Where the workbench is pointed**, as a directory — the reading the
/// Explorer follows. Null when nothing answered, and the caller then holds
/// what it had.
final focusedDirectoryProvider = Provider<EnvironmentPath?>((ref) {
  final tab = ref.watch(
    terminalSessionsControllerProvider.select((s) => s.activeTab),
  );
  final sessionId = ref.watch(activePaneSessionIdProvider);
  final paneId = tab?.focusedPaneId;
  return whereYouAre(
    agentReported: sessionId == null
        ? null
        : ref.watch(agentWorkingDirectoriesProvider)[sessionId],
    paneReported: paneId == null ? null : paneDirectory(ref, paneId),
    recorded: sessionId == null
        ? null
        : sessionWorkingDirectory(ref, sessionId),
  );
});

/// Whether a deliberate Explorer click is holding the selection where it is.
///
/// Set when the user picks something in the tree, released when the **pane**
/// on screen changes: the click survives an agent moving under it, and does
/// not survive you going somewhere else yourself.
class ExplorerFollowHold extends Notifier<bool> {
  @override
  bool build() => false;

  void hold() => state = true;
  void release() {
    if (state) state = false;
  }
}

final explorerFollowHoldProvider = NotifierProvider<ExplorerFollowHold, bool>(
  ExplorerFollowHold.new,
);
