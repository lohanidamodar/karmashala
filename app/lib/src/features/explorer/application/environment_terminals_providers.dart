import '../../workspaces/data/workspace_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show TerminalRecord, kHostedRunPanePrefix, paneIdOfTerminalSession;

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/util/failure_words.dart';
import '../../ssh/data/ssh_client.dart';
import '../../ssh/data/ssh_hosts_data.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/terminals_client.dart';
import 'environment_terminals.dart';

/// Which machine a pane is running on, from its profile id alone.
///
/// Null where the profile cannot say — an `agent:` pane is launched into
/// whatever environment its session names, and filing it under this machine
/// would be a confident false statement.
String? environmentIdOfProfile(String profileId, {required String? localId}) {
  if (profileId.startsWith('wsl:') || profileId.startsWith('ssh:')) {
    return profileId;
  }
  if (profileId == TerminalProfile.powerShellId ||
      profileId == TerminalProfile.commandPromptId ||
      profileId.startsWith('posix:')) {
    return localId;
  }
  return null;
}

/// Every open pane, filed under the machine it runs on.
///
/// The agent panes are resolved through the session each runs here
/// ([PaneSessions]); a pane whose machine cannot be established is left out
/// rather than guessed at.
final panesByEnvironmentProvider =
    Provider<Map<String, List<EnvironmentTerminal>>>((ref) {
      final state = ref.watch(terminalSessionsControllerProvider);
      final controller = ref.read(terminalSessionsControllerProvider.notifier);
      final localId = ref.watch(localEnvironmentProvider)?.id;

      final paneIds = [for (final tab in state.tabs) ...tab.layout.panes];
      final unresolved = <String>[];
      final byEnvironment = <String, List<EnvironmentTerminal>>{};

      void file(String environmentId, String paneId) {
        final instance = controller.instanceFor(paneId);
        if (instance == null) return;
        byEnvironment
            .putIfAbsent(environmentId, () => [])
            .add(
              EnvironmentTerminal(
                id: paneId,
                label: instance.title,
                running: instance.liveness.value.isLive,
                paneId: paneId,
              ),
            );
      }

      for (final paneId in paneIds) {
        final instance = controller.instanceFor(paneId);
        if (instance == null) continue;
        final environmentId = environmentIdOfProfile(
          instance.profileId,
          localId: localId,
        );
        if (environmentId == null) {
          unresolved.add(paneId);
        } else {
          file(environmentId, paneId);
        }
      }

      if (unresolved.isNotEmpty) {
        // A checkout is spelled for the machine it lives on, so the repository
        // row is where a session's environment actually comes from.
        final repositories = {
          for (final repository in ref.read(workspaceDataProvider).repositories)
            repository.id: repository.path.environmentId,
        };
        final panes = ref.read(paneSessionsProvider);
        final rows = ref.read(sessionsDataProvider);
        for (final paneId in unresolved) {
          final sessionId = panes.sessionOf(paneId);
          final session = sessionId == null ? null : rows.getById(sessionId);
          final environmentId = repositories[session?.repositoryId];
          if (environmentId == null) continue;
          file(environmentId, paneId);
        }
      }
      return byEnvironment;
    });

/// The terminals the server runs, as its data link keeps them: greeted whole
/// on subscribe, then kept by each change.
final serverTerminalRecordsProvider = Provider<List<TerminalRecord>>((ref) {
  final client = ref.watch(dataClientProvider);
  final changes = client.terminalChanges.listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  return List.unmodifiable(client.terminals.values);
});

/// Live shells on [environmentId] that no pane here shows. Not an agent's
/// terminal (its session opens it) nor a box's (the box host lists it), nor
/// a hosted run's, whose session id is a shell's but whose pane is not one.
List<EnvironmentTerminal> _serverShellsOn(
  Ref ref,
  String environmentId,
  List<EnvironmentTerminal> panesHere,
) {
  final open = {for (final pane in panesHere) pane.paneId};
  final localId = ref.watch(localEnvironmentProvider)?.id;
  return [
    for (final record in ref.watch(serverTerminalRecordsProvider))
      if (paneIdOfTerminalSession(record.sessionId) case final paneId?)
        if (record.isLive &&
            !paneId.startsWith(kHostedRunPanePrefix) &&
            !open.contains(paneId) &&
            (record.environmentId ??
                    environmentIdOfProfile(
                      record.profileId,
                      localId: localId,
                    ) ??
                    localId) ==
                environmentId)
          EnvironmentTerminal(
            id: record.sessionId,
            label: record.title,
            running: true,
            paneId: paneId,
            hostSessionId: record.sessionId,
            profileId: record.profileId,
          ),
  ];
}

/// **What one machine is holding.**
///
/// Local and WSL read panes already in memory, so the answer is current by
/// construction. A machine reached over SSH runs the session host, which
/// outlives this app — it is asked once, when somebody opens the node, and
/// never on a timer (§19).
final environmentTerminalsProvider = NotifierProvider.autoDispose
    .family<EnvironmentTerminalsController, EnvironmentTerminals, String>(
      EnvironmentTerminalsController.new,
    );

class EnvironmentTerminalsController extends Notifier<EnvironmentTerminals> {
  EnvironmentTerminalsController(this._environmentId);

  final String _environmentId;

  @override
  EnvironmentTerminals build() {
    if (_hostId != null) return EnvironmentTerminals.unasked;
    final panes =
        ref.watch(panesByEnvironmentProvider)[_environmentId] ?? const [];
    return EnvironmentTerminals(
      terminals: ref.watch(capabilitiesProvider).serverTerminalsArea
          ? [...panes, ..._serverShellsOn(ref, _environmentId, panes)]
          : panes,
      readAt: ref.read(clockProvider).nowUtc(),
    );
  }

  String? get _hostId =>
      ref.read(environmentsDataProvider).getById(_environmentId)?.sshHostId;

  /// Asks the machine again. Local and WSL have nothing to ask.
  Future<void> refresh() async {
    final hostId = _hostId;
    if (hostId == null) return;
    final host = ref.read(sshHostsDataProvider).getById(hostId);
    if (host == null) {
      state = EnvironmentTerminals(
        terminals: const [],
        readAt: ref.read(clockProvider).nowUtc(),
        problem: 'This machine no longer names a saved SSH host.',
      );
      return;
    }
    state = EnvironmentTerminals(
      terminals: state.terminals,
      readAt: state.readAt,
      busy: true,
    );
    try {
      final found = await ref.read(sshClientProvider).hostSessions(host.id);
      // A dial outlives the node that started it: collapsing Terminals, or the
      // Explorer rebuilding, disposes this provider while the host is still
      // being asked. Riverpod throws on `ref` after that, and the answer is
      // nobody's to keep.
      if (!ref.mounted) return;
      state = EnvironmentTerminals(
        terminals: [
          for (final session in found)
            EnvironmentTerminal(
              id: session.id,
              label: session.argv.join(' '),
              running: !session.lifecycle.hasEnded,
              paneId: paneIdOfTerminalSession(session.id),
              hostSessionId: session.id,
            ),
        ],
        readAt: ref.read(clockProvider).nowUtc(),
      );
    } on Object catch (e) {
      if (!ref.mounted) return;
      // In the host's own words: "could not look" is a different answer from
      // "nothing is running", and an empty list would tell the second story.
      state = EnvironmentTerminals(
        terminals: const [],
        readAt: ref.read(clockProvider).nowUtc(),
        problem: describeFailure(e),
      );
    }
  }

  /// Ends a hosted session for good, then re-reads. One the server runs on
  /// its own machine leaves the list when the server says it has gone.
  Future<void> end(String hostSessionId) async {
    final hostId = _hostId;
    if (hostId == null) {
      await ref.read(terminalsClientProvider).close(hostSessionId);
      return;
    }
    final host = ref.read(sshHostsDataProvider).getById(hostId);
    if (host == null) return;
    await ref.read(sshClientProvider).endHostSession(host.id, hostSessionId);
    if (!ref.mounted) return;
    await refresh();
  }
}
