import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';

import '../../sessions/application/session_launch_refusal.dart';
import '../../sessions/application/session_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../data/agents_data.dart';
import 'agent_providers.dart';

final _log = AppLogger.named('agents.models');

/// An agent in one environment: an installation in a WSL distribution or on
/// an SSH box is another version with another account's list than the host's.
typedef AgentModelsKey = ({String agentId, String environmentId});

/// The models [agentId]'s CLI reports on this machine, as the server keeps
/// them, or null when it has no list to read.
final discoveredModelsProvider =
    FutureProvider.family<AgentModelCatalog?, String>(
      (ref, agentId) => ref.watch(
        discoveredModelsInProvider((
          agentId: agentId,
          environmentId: localHostEnvironmentId,
        )).future,
      ),
    );

/// The models an agent's CLI reports **in one environment**, as the server
/// read and cached them (`agents.models`), or null when there is no such
/// installation, its agent lists none, or the server could not be asked. An
/// empty catalogue is no list either: the curated one stands.
final discoveredModelsInProvider =
    FutureProvider.family<AgentModelCatalog?, AgentModelsKey>((ref, key) async {
      final installation = _installationOf(ref, key);
      if (installation == null) return null;
      final adapter = ref.read(agentRegistryProvider).adapterFor(key.agentId);
      if (adapter?.modelLister == null) return null;
      try {
        return await ref.read(agentWorkProvider).models(installation.id);
      } on Object catch (error) {
        _log.debug('${key.agentId} models not read: $error');
        return null;
      }
    });

AgentInstallation? _installationOf(Ref ref, AgentModelsKey key) => ref
    .read(agentInstallationsDataProvider)
    .getAll()
    .where(
      (i) =>
          i.agentId == key.agentId &&
          i.executable.environmentId == key.environmentId,
    )
    .firstOrNull;

/// Asks the server to read [key]'s list from the agent now, then re-reads
/// the cached answer, and answers what the server holds afterwards. Never
/// throws: a failed read keeps the last list, and the catalogue says why;
/// null when the server could not be asked at all.
final agentModelsRefreshProvider =
    Provider<Future<AgentModelCatalog?> Function(AgentModelsKey key)>(
      (ref) => (key) async {
        final installation = _installationOf(ref, key);
        if (installation == null) return null;
        AgentModelCatalog? read;
        try {
          read = await ref
              .read(agentWorkProvider)
              .models(installation.id, refresh: true);
        } on Object catch (error) {
          _log.debug('${key.agentId} models not refreshed: $error');
        }
        ref.invalidate(discoveredModelsInProvider(key));
        return read;
      },
    );

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
/// a session's own picker offers: the agent's live ids, labelled by the
/// curated list where the agent left them bare (`mergeModelLists`).
final agentModelSupportInProvider =
    Provider.family<AgentModelSupport, AgentModelsKey>((ref, key) {
      final base =
          ref.watch(agentRegistryProvider).byId(key.agentId)?.launch.model ??
          const AgentModelSupport.unsupported();
      if (!base.isSupported) return base;
      // `.value` keeps the last list while a re-read is in flight.
      final catalog = ref.watch(discoveredModelsInProvider(key)).value;
      if (catalog == null || !catalog.isLive) return base;
      return base.withModels(
        mergeModelLists(curated: base.models, live: catalog.models),
      );
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
    final refresh = ref.read(agentModelsRefreshProvider);
    for (final paneId in started) {
      final sessionId = controller.instanceFor(paneId)?.agentLaunch?.sessionId;
      if (sessionId == null) continue;
      final key = agentModelsKeyOfSession(ref, sessionId);
      if (key == null) continue;
      unawaited(refresh(key));
      late final Timer timer;
      timer = Timer(kModelsRereadAfterStart, () {
        pending.remove(timer);
        unawaited(refresh(key));
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
