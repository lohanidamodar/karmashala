import 'package:agent_cli/descriptors.dart';

/// The registry's id for a CLI name a caller wrote — the id itself, or a
/// name its adapter declares — or null when nothing matches it. Asked of the
/// adapters, never compared against a known agent here.
String? agentIdForName(AgentRegistry agents, String? cli) {
  if (cli == null) return null;
  final normalized = cli.trim().toLowerCase();
  for (final adapter in agents.adapters) {
    if (adapter.id.toLowerCase() == normalized) return adapter.id;
  }
  for (final adapter in agents.adapters) {
    if (adapter.aliases.contains(normalized)) return adapter.id;
  }
  return null;
}
