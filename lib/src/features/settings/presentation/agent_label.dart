import 'package:agent_cli/descriptors.dart';

/// An agent id as a person reads it — "Claude Code" rather than `claude`.
///
/// Shared by the settings surfaces that name an agent (the Agents page header,
/// the model cards, the usage cards) so they cannot drift into three spellings
/// of the same thing.
String agentLabel(String agentId) =>
    AgentRegistry.builtIn.displayNameFor(agentId);
