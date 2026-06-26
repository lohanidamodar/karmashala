import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../agents/data/fake_agent_adapter.dart';
import '../../agents/domain/agent_adapter.dart';
import '../../git/application/git_providers.dart';
import 'session_engine.dart';
import 'session_providers.dart';

/// Resolves the [AgentAdapter] for an agent kind.
///
/// Loop 6 returns a [FakeAgentAdapter] for every kind. Real adapters (Codex,
/// Claude Code, Antigravity) are registered here in later loops.
final agentAdapterResolverProvider = Provider<AdapterResolver>((ref) {
  return (kind) => FakeAgentAdapter(kind: kind);
});

/// Provides the singleton [SessionEngine] for the app.
final sessionEngineProvider = Provider<SessionEngine>(
  (ref) => SessionEngine(
    sessionDao: ref.watch(sessionDaoProvider),
    eventDao: ref.watch(sessionEventDaoProvider),
    worktreeService: ref.watch(worktreeServiceProvider),
    resolveAdapter: ref.watch(agentAdapterResolverProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  ),
);
