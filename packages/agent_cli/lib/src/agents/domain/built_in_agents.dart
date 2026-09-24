import '../../permissions/permission_risk.dart';
import './agent_descriptor.dart';
import './agent_kind.dart';
import './agent_mcp_config.dart';
import './agent_plan.dart';
import './agent_question.dart';
import './agent_screen_menu.dart';
import './agent_permission_support.dart';
import './agent_skill_support.dart';
import './agent_status.dart';

part 'built_in_agents/antigravity.dart';
part 'built_in_agents/claude_code.dart';
part 'built_in_agents/codex.dart';

/// The agents Karmashala ships knowledge of.
///
/// This list is **data**: everything the app needs to find, launch and observe
/// these agents is here rather than spread through discovery, store location
/// and terminal code. The three entries also have protocol adapters, which is
/// why each carries an [AgentKind]; a fourth agent added here without one is
/// discovered, persisted, listed and openable just the same — it simply gets
/// the generic adapter and no rich chat.
///
/// Order matters: it is the order agents are probed and listed in.
const List<AgentDescriptor> builtInAgentDescriptors = [
  _claudeCode,
  _codex,
  _antigravity,
];
