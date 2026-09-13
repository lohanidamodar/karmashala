import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../ssh/application/host_sessions.dart';
import '../../ssh/application/ssh_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
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
/// The agent panes are resolved through their sessions in **one** indexed
/// query rather than one per pane; a pane whose machine cannot be established
/// is left out rather than guessed at.
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
        byEnvironment.putIfAbsent(environmentId, () => []).add(
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
          for (final repository in ref.read(repositoryDaoProvider).getAll())
            repository.id: repository.path.environmentId,
        };
        for (final session in ref
            .read(sessionDaoProvider)
            .getByPaneIds(unresolved)) {
          final environmentId = repositories[session.repositoryId];
          final paneId = session.paneId;
          if (environmentId == null || paneId == null) continue;
          file(environmentId, paneId);
        }
      }
      return byEnvironment;
    });

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
    return EnvironmentTerminals(
      terminals:
          ref.watch(panesByEnvironmentProvider)[_environmentId] ?? const [],
      readAt: ref.read(clockProvider).nowUtc(),
    );
  }

  String? get _hostId => ref
      .read(executionEnvironmentDaoProvider)
      .getById(_environmentId)
      ?.sshHostId;

  /// Asks the machine again. Local and WSL have nothing to ask.
  Future<void> refresh() async {
    final hostId = _hostId;
    if (hostId == null) return;
    final host = ref.read(sshHostDaoProvider).getById(hostId);
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
      final found = await ref.read(hostSessionsServiceProvider).list(host);
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
              paneId: paneIdOfHostSession(session.id, host.id),
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
        problem: e is HostSessionsUnavailable ? e.message : '$e',
      );
    }
  }

  /// Ends a hosted session for good, then re-reads.
  Future<void> end(String hostSessionId) async {
    final hostId = _hostId;
    if (hostId == null) return;
    final host = ref.read(sshHostDaoProvider).getById(hostId);
    if (host == null) return;
    await ref.read(hostSessionsServiceProvider).end(host, hostSessionId);
    if (!ref.mounted) return;
    await refresh();
  }
}
