import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_resolver.dart';
import '../../git/application/git_providers.dart';
import 'session_engine.dart';
import 'session_providers.dart';

/// Resolves the [AgentAdapter] for an agent id: the three with a hand-written
/// adapter come off `AgentKind`, and anything else gets the generic one.
final agentAdapterResolverProvider = Provider<AdapterResolver>((ref) {
  final runnerFor = ref.watch(runnerResolverProvider);
  final registry = ref.watch(agentRegistryProvider);
  return (agentId) {
    final descriptor = registry.byId(agentId);
    return switch (descriptor?.kind) {
      AgentKind.codex => CodexAdapter(runnerFor: runnerFor),
      AgentKind.claudeCode => ClaudeCodeAdapter(runnerFor: runnerFor),
      AgentKind.antigravity => AntigravityAdapter(runnerFor: runnerFor),
      null => GenericAgentAdapter(
        agentId: agentId,
        launch: descriptor?.launch ?? const AgentLaunchSpec(),
        runnerFor: runnerFor,
      ),
    };
  };
});

/// Provides the singleton [SessionEngine] for the app.
final sessionEngineProvider = Provider<SessionEngine>((ref) {
  final engine = SessionEngine(
    sessionDao: ref.watch(sessionDaoProvider),
    eventDao: ref.watch(sessionEventDaoProvider),
    sessionRepositoryDao: ref.watch(sessionRepositoryDaoProvider),
    worktreeService: ref.watch(worktreeServiceProvider),
    resolveAdapter: ref.watch(agentAdapterResolverProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  );
  // The engine holds a child process and a subscription per active run, and
  // nothing else ends them — container disposal tore down neither.
  ref.onDispose(engine.dispose);
  return engine;
});
