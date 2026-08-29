import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/data/antigravity_adapter.dart';
import '../../agents/data/claude_code_adapter.dart';
import '../../agents/data/codex_adapter.dart';
import '../../agents/data/generic_agent_adapter.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_kind.dart';
import '../../environments/application/environment_providers.dart';
import '../../git/application/git_providers.dart';
import 'session_engine.dart';
import 'session_providers.dart';

/// Resolves the [AgentAdapter] for an agent id.
///
/// The three agents with a hand-written protocol adapter are selected through
/// their descriptor's `AgentKind` — which is now what that enum *means*: "this
/// agent has an adapter". Everything else, including an id no descriptor claims
/// any more, falls to [GenericAgentAdapter] rather than crashing.
final agentAdapterResolverProvider = Provider<AdapterResolver>((ref) {
  final runnerFactory = ref.watch(commandRunnerFactoryProvider);
  final environmentDao = ref.watch(executionEnvironmentDaoProvider);
  final registry = ref.watch(agentRegistryProvider);
  return (agentId) {
    final descriptor = registry.byId(agentId);
    return switch (descriptor?.kind) {
      AgentKind.codex => CodexAdapter(
        runnerFactory: runnerFactory,
        environmentDao: environmentDao,
      ),
      AgentKind.claudeCode => ClaudeCodeAdapter(
        runnerFactory: runnerFactory,
        environmentDao: environmentDao,
      ),
      AgentKind.antigravity => AntigravityAdapter(
        runnerFactory: runnerFactory,
        environmentDao: environmentDao,
      ),
      null => GenericAgentAdapter(
        agentId: agentId,
        launch: descriptor?.launch ?? const AgentLaunchSpec(),
        runnerFactory: runnerFactory,
        environmentDao: environmentDao,
      ),
    };
  };
});

/// Provides the singleton [SessionEngine] for the app.
final sessionEngineProvider = Provider<SessionEngine>(
  (ref) => SessionEngine(
    sessionDao: ref.watch(sessionDaoProvider),
    eventDao: ref.watch(sessionEventDaoProvider),
    sessionRepositoryDao: ref.watch(sessionRepositoryDaoProvider),
    worktreeService: ref.watch(worktreeServiceProvider),
    resolveAdapter: ref.watch(agentAdapterResolverProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  ),
);
