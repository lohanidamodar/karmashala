import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../data/agent_hook_installer.dart';
import '../data/agent_hook_receiver.dart';
import '../data/agent_status_service.dart';
import 'agent_providers.dart';

/// The live hook-reported statuses. One store for the whole app: the receiver
/// writes into it and the status service reads from it.
final agentHookReportsProvider = Provider<AgentHookReports>(
  (ref) => AgentHookReports(),
);

final agentHookReceiverProvider = Provider<AgentHookReceiver>(
  (ref) => AgentHookReceiver(
    registry: ref.watch(agentRegistryProvider),
    reports: ref.watch(agentHookReportsProvider),
    clock: ref.watch(clockProvider),
  ),
);

final agentHookInstallerProvider = Provider<AgentHookInstaller>(
  (ref) => const AgentHookInstaller(),
);

final agentStatusServiceProvider = Provider<AgentStatusService>(
  (ref) => AgentStatusService(
    registry: ref.watch(agentRegistryProvider),
    hookReports: ref.watch(agentHookReportsProvider),
    clock: ref.watch(clockProvider),
  ),
);
