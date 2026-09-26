import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/lifecycle_client.dart' show HookEndpoint;
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/local_host_providers.dart';

/// Whether local agents' hooks go to this machine's server rather than the
/// app's own `/agent-hook` route: whenever a server may be reached, whatever
/// runs the panes — the server takes every turn's checkpoint, adopts, and
/// keeps status from them (slice 2b), and relays each hook to the app. The
/// WSL spool is the app's either way.
final agentHooksAtHostProvider = Provider<bool>(
  (ref) => ref.watch(localHostSessionAccessProvider) != null,
);

/// What the hook installer is given: the session host's endpoint when hooks go
/// there — spool only until that host has written one — else [appRoute].
AgentHookEndpoint? installableHookEndpoint(
  ProviderContainer container, {
  required AgentHookEndpoint? appRoute,
}) {
  if (!container.read(agentHooksAtHostProvider)) return appRoute;
  return hostHookEndpoint(container) ?? const AgentHookEndpoint.spoolOnly();
}

/// The session host's hook endpoint, read from its directory; null when no host
/// has served hooks there.
AgentHookEndpoint? hostHookEndpoint(ProviderContainer container) {
  final access = container.read(localHostSessionAccessProvider);
  if (access == null) return null;
  final endpoint = HookEndpoint.read(access.paths.hookEndpointPath);
  if (endpoint == null) return null;
  return AgentHookEndpoint(port: endpoint.port, token: endpoint.token);
}
