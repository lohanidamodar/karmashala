import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../sessions/application/session_launch_refusal.dart';
import '../../sessions/application/session_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'agent_providers.dart';

final _log = AppLogger.named('agents.models');

/// An agent in one environment: an installation in a WSL distribution is
/// another version with another account's list than the host's.
typedef AgentModelsKey = ({String agentId, String environmentId});

/// The models [agentId]'s own CLI reports on this machine, or null when it has
/// no list to read or would not give one. Null is not an empty account: the
/// curated list stands in for it.
final discoveredModelsProvider =
    FutureProvider.family<List<AgentModel>?, String>(
      (ref, agentId) => ref.watch(
        discoveredModelsInProvider((
          agentId: agentId,
          environmentId: localHostEnvironmentId,
        )).future,
      ),
    );

/// The models an agent's own CLI reports **in one environment**, or null.
/// Read again whenever it is invalidated — [agentModelsRefresherProvider] does
/// that as a session of the agent starts, so the list is the CLI's newest.
final discoveredModelsInProvider =
    FutureProvider.family<List<AgentModel>?, AgentModelsKey>((ref, key) async {
      final adapter = ref.read(agentRegistryProvider).adapterFor(key.agentId);
      final lister = adapter?.modelLister;
      if (lister == null) return null;
      final context = _contextFor(ref, key);
      // An environment this app runs nothing in (an SSH box): the host's list
      // would be a claim about another machine.
      if (context == null) return null;
      try {
        final found = await lister.list(context);
        if (found != null) {
          _log.info(
            '${key.agentId} lists ${found.length} model(s) in '
            '${key.environmentId}',
          );
        }
        return found;
      } on Object catch (error) {
        _log.debug('${key.agentId} would not list its models: $error');
        return null;
      }
    });

/// How [agentId] is told a model on this machine, offering the list its CLI
/// reported where one was read and the curated list until then.
final agentModelSupportProvider = Provider.family<AgentModelSupport, String>(
  (ref, agentId) => ref.watch(
    agentModelSupportInProvider((
      agentId: agentId,
      environmentId: localHostEnvironmentId,
    )),
  ),
);

/// [agentModelSupportProvider] for the installation in one environment — what
/// a session's own picker offers.
final agentModelSupportInProvider =
    Provider.family<AgentModelSupport, AgentModelsKey>((ref, key) {
      final base =
          ref.watch(agentRegistryProvider).byId(key.agentId)?.launch.model ??
          const AgentModelSupport.unsupported();
      if (!base.isSupported) return base;
      // `.value` keeps the last list while a re-read is in flight.
      final found = ref.watch(discoveredModelsInProvider(key)).value;
      return found == null ? base : base.withModels(found);
    });

/// How long after a session starts its agent's list is read a second time: a
/// CLI refreshes its own catalogue as it starts, a moment after the launch.
const Duration kModelsRereadAfterStart = Duration(seconds: 15);

/// Reads an agent's models again as a session of it starts — once at once and
/// once after [kModelsRereadAfterStart] — so the picker offers what that CLI
/// offers now, not what it listed when the app opened (owner, 2026-09-30).
/// **Watched, not read**, like the refused-launch reporter beside it.
final agentModelsRefresherProvider = Provider<void>((ref) {
  final pending = <Timer>{};
  ref.onDispose(() {
    for (final timer in pending) {
      timer.cancel();
    }
  });
  ref.listen(terminalSessionsControllerProvider, (previous, next) {
    final started = panesThatStartedRunning(previous?.liveness, next.liveness);
    if (started.isEmpty) return;
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    for (final paneId in started) {
      final sessionId = controller.instanceFor(paneId)?.agentLaunch?.sessionId;
      if (sessionId == null) continue;
      final key = agentModelsKeyOfSession(ref, sessionId);
      if (key == null) continue;
      ref.invalidate(discoveredModelsInProvider(key));
      late final Timer timer;
      timer = Timer(kModelsRereadAfterStart, () {
        pending.remove(timer);
        ref.invalidate(discoveredModelsInProvider(key));
      });
      pending.add(timer);
    }
  });
});

/// The agent and environment behind session [sessionId], or null for a row
/// or an installation that is gone.
AgentModelsKey? agentModelsKeyOfSession(Ref ref, String sessionId) {
  final session = ref.read(sessionsDataProvider).getById(sessionId);
  if (session == null) return null;
  final installation = ref
      .read(agentInstallationsDataProvider)
      .getById(session.agentInstallationId);
  if (installation == null) return null;
  return (
    agentId: installation.agentId,
    environmentId: installation.executable.environmentId,
  );
}

/// What a listing may need: this host's environment, and a way to run the
/// agent's installation — or a command — in [key]'s environment. Null when
/// that environment is one this app runs nothing in. The installation is
/// looked up only when a lister runs it, so one that reads a file never
/// touches the table.
ModelListContext? _contextFor(Ref ref, AgentModelsKey key) {
  final onHost = key.environmentId == localHostEnvironmentId;
  final CommandRunner runner;
  if (onHost) {
    runner = ref.read(hostCommandRunnerProvider);
  } else {
    final environment = ref
        .read(environmentsControllerProvider)
        .where((e) => e.id == key.environmentId)
        .firstOrNull;
    if (environment == null || environment.kind != EnvironmentKind.wsl) {
      return null;
    }
    runner = ref.read(commandRunnerFactoryProvider).forEnvironment(environment);
  }
  return ModelListContext(
    hostEnvironment: ref.read(hostEnvironmentProvider),
    hostIsWindows: Platform.isWindows,
    runLocalCli:
        (arguments, {stdinText, timeout = const Duration(seconds: 30)}) async {
          final installation = ref
              .read(agentInstallationsDataProvider)
              .getAll()
              .where(
                (i) =>
                    i.agentId == key.agentId &&
                    i.executable.environmentId == key.environmentId,
              )
              .firstOrNull;
          if (installation == null) return null;
          final result = await runner.run(
            CommandRequest(
              executable: installation.executable.path,
              arguments: arguments,
              stdinText: stdinText,
              timeout: timeout,
            ),
          );
          return result.ok ? result.stdout : null;
        },
    runInEnvironment: onHost
        ? null
        : (executable, arguments) async {
            final result = await runner.run(
              CommandRequest(executable: executable, arguments: arguments),
            );
            return result.ok ? result.stdout : null;
          },
  );
}
