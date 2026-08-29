import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../data/agent_hook_installer.dart';
import '../data/agent_hook_receiver.dart';
import '../data/agent_hook_server.dart';
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

/// Hosts the loopback endpoint agents' hooks call back into. Started by the
/// app; disposing the provider closes the port.
final agentHookServerProvider = Provider<AgentHookServer>((ref) {
  final server = AgentHookServer(ref.watch(agentHookReceiverProvider));
  ref.onDispose(server.stop);
  return server;
});

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
