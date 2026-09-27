import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
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
