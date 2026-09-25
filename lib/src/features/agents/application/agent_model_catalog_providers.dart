import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';

import '../../../core/process/command_runner_providers.dart';
import 'agent_providers.dart';

final _log = AppLogger.named('agents.models');

/// The models [agentId]'s own CLI reports on this machine, read once per run,
/// or null when it has no list to read or would not give one. Null is not an
/// empty account: the curated list stands in for it.
final discoveredModelsProvider =
    FutureProvider.family<List<AgentModel>?, String>((ref, agentId) async {
      final adapter = ref.read(agentRegistryProvider).adapterFor(agentId);
      final lister = adapter?.modelLister;
      if (lister == null) return null;
      try {
        final found = await lister.list(_contextFor(ref, agentId));
        if (found != null) {
          _log.info('$agentId lists ${found.length} model(s) for this account');
        }
        return found;
      } on Object catch (error) {
        _log.debug('$agentId would not list its models: $error');
        return null;
      }
    });

/// How [agentId] is told a model, offering the list its CLI reported where one
/// was read and the curated list until then.
final agentModelSupportProvider = Provider.family<AgentModelSupport, String>((
  ref,
  agentId,
) {
  final base =
      ref.watch(agentRegistryProvider).byId(agentId)?.launch.model ??
      const AgentModelSupport.unsupported();
  if (!base.isSupported) return base;
  final found = ref.watch(discoveredModelsProvider(agentId)).value;
  return found == null ? base : base.withModels(found);
});

/// What a listing may need from this host: its environment, and a way to run
/// [agentId]'s installation on this machine. The installation is looked up only
/// when a lister runs it, so one that reads a file never touches the table.
ModelListContext _contextFor(Ref ref, String agentId) {
  return ModelListContext(
    hostEnvironment: ref.read(hostEnvironmentProvider),
    hostIsWindows: Platform.isWindows,
    runLocalCli:
        (arguments, {stdinText, timeout = const Duration(seconds: 30)}) async {
          final installation = ref
              .read(agentInstallationDaoProvider)
              .getAll()
              .where(
                (i) =>
                    i.agentId == agentId &&
                    i.executable.environmentId == localHostEnvironmentId,
              )
              .firstOrNull;
          if (installation == null) return null;
          final result = await ref
              .read(hostCommandRunnerProvider)
              .run(
                CommandRequest(
                  executable: installation.executable.path,
                  arguments: arguments,
                  stdinText: stdinText,
                  timeout: timeout,
                ),
              );
          return result.ok ? result.stdout : null;
        },
  );
}
