import 'package:agent_cli/descriptors.dart';

/// An agent id as a person reads it — "Claude Code" rather than `claude`.
/// Shared, so the settings surfaces cannot drift into three spellings of it.
String agentLabel(String agentId) =>
    AgentRegistry.builtIn.displayNameFor(agentId);
