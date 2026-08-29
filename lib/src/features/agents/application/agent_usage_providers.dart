import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../data/agent_usage_service.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_usage.dart';

/// Fetches live usage/limits for an agent installation.
final agentUsageServiceProvider = Provider<AgentUsageService>(
  (ref) => AgentUsageService(
    storeLocator: ref.watch(cliStoreLocatorProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Live usage for one installation, fetched on demand. `autoDispose` so it
/// refetches when re-viewed rather than caching a stale snapshot; invalidate to
/// force a refresh.
final agentUsageProvider = FutureProvider.autoDispose
    .family<AgentUsage, AgentInstallation>((ref, installation) async {
      final environments = ref.watch(executionEnvironmentDaoProvider).getAll();
      return ref
          .watch(agentUsageServiceProvider)
          .fetch(installation, environments);
    });
