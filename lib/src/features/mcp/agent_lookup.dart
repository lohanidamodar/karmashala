import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agents/application/agent_providers.dart';
import '../agents/domain/agent_ids.dart';
import '../agents/domain/agent_installation.dart';
import '../agents/domain/agent_permission_support.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/domain/session_launch.dart';

/// The lookups the tool families share now that they no longer sit in one
/// class together: which agent a caller meant, which installation that is, and
/// what permission a resume runs under.
///
/// Here rather than in one of the families because each has two callers —
/// [parseCli] the inventory and launch tools, the other two the launch and tmux
/// tools — and a copy apiece would be a chance for the answers to diverge.

/// The registry's id for a CLI name a caller wrote, or null when nothing
/// matches it.
String? parseCli(ProviderContainer container, String? cli) {
  if (cli == null) return null;
  final normalized = cli.trim().toLowerCase();
  for (final descriptor in container.read(agentRegistryProvider).descriptors) {
    if (descriptor.id.toLowerCase() == normalized) return descriptor.id;
  }
  if (normalized == 'claude' || normalized == 'claude code') {
    return AgentIds.claudeCode;
  }
  return null;
}

/// The first installation of [agentId], optionally pinned to one environment.
AgentInstallation? installFor(
  ProviderContainer container,
  String agentId,
  String? environmentId,
) {
  for (final install in container.read(agentInstallationDaoProvider).getAll()) {
    if (install.agentId != agentId) continue;
    if (environmentId != null && install.environmentId != environmentId) {
      continue;
    }
    return install;
  }
  return null;
}

/// Both callers are resuming a conversation the agent already has, so both
/// ask for the existing-session mode — through the launcher, which is the one
/// place that turns a purpose into a selection.
PermissionSelection resumePermissionFor(
  ProviderContainer container,
  String agentId,
) => container
    .read(sessionLauncherProvider)
    .permissionFor(agentId, SessionPurpose.existingSession);
