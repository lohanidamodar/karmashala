import 'package:riverpod/riverpod.dart';

import '../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import '../sessions/application/session_launcher.dart';
import 'package:karmashala_session/launch.dart';

/// The registry's id for a CLI name a caller wrote, or null when nothing
/// matches it.
String? parseCli(ProviderContainer container, String? cli) {
  if (cli == null) return null;
  final normalized = cli.trim().toLowerCase();
  final adapters = container.read(agentRegistryProvider).adapters;
  for (final adapter in adapters) {
    if (adapter.id.toLowerCase() == normalized) return adapter.id;
  }
  // The names a caller writes for an agent, which its adapter declares.
  for (final adapter in adapters) {
    if (adapter.aliases.contains(normalized)) return adapter.id;
  }
  return null;
}

/// The first installation of [agentId], optionally pinned to one environment.
AgentInstallation? installFor(
  ProviderContainer container,
  String agentId,
  String? environmentId,
) {
  for (final install
      in container.read(agentInstallationsDataProvider).getAll()) {
    if (install.agentId != agentId) continue;
    if (environmentId != null && install.environmentId != environmentId) {
      continue;
    }
    return install;
  }
  return null;
}

/// Both callers are resuming a conversation the agent already has, so both ask
/// for the existing-session mode, through the launcher.
PermissionSelection resumePermissionFor(
  ProviderContainer container,
  String agentId,
) => container
    .read(sessionLauncherProvider)
    .permissionFor(agentId, SessionPurpose.existingSession);
