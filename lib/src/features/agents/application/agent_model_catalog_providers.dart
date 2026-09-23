import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/process/command_runner_providers.dart';
import 'agent_providers.dart';

final _log = AppLogger.named('agents.models');

/// The models [agentId]'s own CLI reports on this machine, read once per run,
/// or null when it has no list to read or would not give one. Null is not an
/// empty account: the curated list stands in for it.
final discoveredModelsProvider =
    FutureProvider.family<List<AgentModel>?, String>((ref, agentId) async {
      final support = ref
          .read(agentRegistryProvider)
          .byId(agentId)
          ?.launch
          .model;
      if (support == null) return null;
      try {
        final found = switch (support.discovery) {
          AgentModelDiscovery.none => null,
          AgentModelDiscovery.codexModelsCache => await _codexModels(ref),
          AgentModelDiscovery.claudeListModels => await _claudeModels(
            ref,
            agentId,
          ),
        };
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

Future<List<AgentModel>?> _codexModels(Ref ref) async {
  final env = ref.read(hostEnvironmentProvider);
  final home =
      env['CODEX_HOME'] ??
      p.join(
        (Platform.isWindows ? env['USERPROFILE'] : env['HOME']) ?? '.',
        '.codex',
      );
  final cache = File(p.join(home, 'models_cache.json'));
  if (!await cache.exists()) return null;
  return parseCodexModelsCache(await cache.readAsString());
}

Future<List<AgentModel>?> _claudeModels(Ref ref, String agentId) async {
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
          arguments: kClaudeListModelsArguments,
          stdinText: kClaudeListModelsRequest,
          timeout: const Duration(seconds: 30),
        ),
      );
  return result.ok ? parseClaudeModelList(result.stdout) : null;
}
