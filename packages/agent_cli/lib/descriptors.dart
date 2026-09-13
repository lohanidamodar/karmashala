/// **The table the other four modes read.**
///
/// One `AgentDescriptor` per CLI, and everything the package needs to find,
/// launch, ask, read and account for that CLI is data on it rather than code
/// somewhere: which binaries to look for, how a prompt and a model are passed,
/// what resume looks like, where the store is, what its permission modes are
/// called and what evidence each of those was read off. Adding an agent is
/// adding a descriptor.
library;

export 'src/agents/domain/agent_descriptor.dart';
// The other half of the `AgentHookSpec` a descriptor declares: where an agent's
// hooks report to, and over which transport. Here rather than in a mode of its
// own because installing them is the host's job — this package only says what
// each CLI supports.
export 'src/agents/domain/agent_hook_endpoint.dart';
export 'src/agents/domain/agent_hook_transport.dart';
export 'src/agents/domain/agent_ids.dart';
export 'src/agents/domain/agent_kind.dart';
export 'src/agents/domain/agent_mcp_config.dart';
export 'src/agents/domain/agent_model_options.dart';
export 'src/agents/domain/agent_permission_options.dart';
export 'src/agents/domain/agent_permission_support.dart';
export 'src/agents/domain/agent_plan.dart';
export 'src/agents/domain/agent_registry.dart';
export 'src/agents/domain/agent_skill_support.dart';
export 'src/agents/domain/agent_status.dart';
export 'src/agents/domain/built_in_agents.dart';
export 'src/agents/domain/karmashala_skill.dart';
export 'src/agents/domain/permission_carry.dart';
export 'src/permissions/permission_risk.dart';
