import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/stream.dart';
import '../../environments/application/environment_resolver.dart';
import '../../git/application/git_providers.dart';
import 'session_engine.dart';
import 'session_providers.dart';

/// Resolves the [AgentChatProtocol] for an agent id: whatever its adapter
/// speaks, and — for an installation whose agent left the registry — the
/// generic protocol, which runs the executable with no arguments.
final chatProtocolResolverProvider = Provider<ChatProtocolResolver>((ref) {
  final runnerFor = ref.watch(runnerResolverProvider);
  final registry = ref.watch(agentRegistryProvider);
  return (agentId) =>
      registry.adapterFor(agentId)?.chatProtocol(runnerFor) ??
      GenericChatProtocol(agentId: agentId, runnerFor: runnerFor);
});

/// Provides the singleton [SessionEngine] for the app.
final sessionEngineProvider = Provider<SessionEngine>((ref) {
  final engine = SessionEngine(
    sessions: ref.watch(sessionsDataProvider),
    records: ref.watch(sessionRecordsProvider),
    worktreeService: ref.watch(worktreeServiceProvider),
    resolveProtocol: ref.watch(chatProtocolResolverProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  );
  // The engine holds a child process and a subscription per active run, and
  // nothing else ends them — container disposal tore down neither.
  ref.onDispose(engine.dispose);
  return engine;
});
