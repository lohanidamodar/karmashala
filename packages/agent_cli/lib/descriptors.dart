/// **The agents, behind one boundary.**
///
/// One `AgentAdapter` per CLI, in its own folder under `src/agents/<agent>/`:
/// its `AgentDescriptor` — which binaries to look for, how a prompt and a
/// model are passed, what resume looks like, where the store is, what its
/// permission modes are called and what evidence each of those was read off —
/// plus the capabilities that need code (its chat protocol, its store, its
/// usage endpoint, …), each null where the agent lacks it. Adding an agent is
/// adding an adapter and registering it in an `AgentRegistry`.
library;

export 'src/agents/adapter/agent_accounts.dart';
export 'src/agents/adapter/agent_artifact_markers.dart';
export 'src/agents/adapter/agent_adapter.dart';
export 'src/agents/adapter/agent_capability.dart';
export 'src/agents/adapter/agent_directory_conversations.dart';
export 'src/agents/adapter/agent_file_changes.dart';
export 'src/agents/adapter/agent_import_audit.dart';
export 'src/agents/adapter/agent_media_reader.dart';
export 'src/agents/adapter/agent_model_lister.dart';
export 'src/agents/adapter/agent_presentation.dart';
export 'src/agents/adapter/agent_rewind.dart';
export 'src/agents/adapter/agent_rewind_points.dart';
export 'src/agents/adapter/agent_stats.dart';
export 'src/agents/adapter/agent_store.dart';
export 'src/agents/adapter/agent_store_editor.dart';
export 'src/agents/adapter/agent_store_server.dart';
export 'src/agents/adapter/agent_transcripts.dart';
export 'src/agents/adapter/injected_context.dart';
export 'src/agents/adapter/agent_usage_endpoint.dart';
export 'src/agents/adapter/agent_usage_support.dart';
export 'src/agents/adapter/built_in_agent_adapters.dart';
export 'src/agents/adapter/data_only_agent_adapter.dart';
export 'src/agents/adapter/directory_conversation_attribution.dart';
export 'src/agents/adapter/directory_resume_plan.dart';
export 'src/agents/adapter/transcript_media_block.dart';
export 'src/agents/adapter/usage_limit_evidence.dart';
export 'src/agents/acp/acp_agent_rows.dart';
export 'src/agents/acp/acp_agents.dart';
export 'src/agents/acp/acp_managed_install.dart';
export 'src/agents/acp/acp_registry.dart';
export 'src/agents/acp/claude_acp_descriptor.dart';
export 'src/agents/acp/codex_acp_descriptor.dart';
export 'src/agents/acp/antigravity_acp_descriptor.dart';
export 'src/agents/acp/grok_descriptor.dart';
export 'src/agents/antigravity/antigravity_adapter.dart';
export 'src/agents/antigravity/antigravity_descriptor.dart';
export 'src/agents/antigravity/antigravity_store.dart';
export 'src/agents/claude_code/claude_code_adapter.dart';
export 'src/agents/claude_code/claude_code_descriptor.dart';
export 'src/agents/claude_code/claude_code_store.dart';
export 'src/agents/claude_code/claude_model_list.dart';
export 'src/agents/claude_code/claude_rewind.dart';
export 'src/agents/codex/codex_adapter.dart';
export 'src/agents/codex/codex_descriptor.dart';
export 'src/agents/codex/codex_store.dart';
export 'src/agents/codex/codex_visualize_markers.dart';
export 'src/agents/codex/codex_models_cache.dart';
export 'src/agents/domain/agent_descriptor.dart';
// The other half of the `AgentHookSpec` a descriptor declares: where an agent's
// hooks report to, and over which transport. Here rather than in a mode of its
// own because installing them is the host's job — this package only says what
// each CLI supports.
export 'src/agents/domain/agent_forms.dart';
export 'src/agents/domain/agent_hook_endpoint.dart';
export 'src/agents/domain/agent_hook_transport.dart';
export 'src/agents/domain/agent_ids.dart';
export 'src/agents/domain/agent_mcp_config.dart';
export 'src/agents/domain/agent_model_options.dart';
export 'src/agents/domain/agent_permission_options.dart';
export 'src/agents/domain/agent_permission_support.dart';
export 'src/agents/domain/agent_plan.dart';
export 'src/agents/domain/agent_plan_approval.dart';
export 'src/agents/domain/agent_question.dart';
export 'src/agents/domain/agent_screen_menu.dart';
export 'src/agents/domain/agent_registry.dart';
export 'src/agents/domain/agent_skill_support.dart';
export 'src/agents/domain/agent_status.dart';
export 'src/agents/domain/agent_tool_ask.dart';
export 'src/agents/domain/karmashala_skill.dart';
export 'src/agents/domain/parent_session_environment.dart';
export 'src/agents/domain/permission_carry.dart';
export 'src/permissions/permission_risk.dart';
