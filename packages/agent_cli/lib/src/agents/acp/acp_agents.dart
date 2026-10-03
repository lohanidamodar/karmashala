import '../adapter/agent_presentation.dart';
import '../adapter/data_only_agent_adapter.dart';
import 'antigravity_acp_descriptor.dart';
import 'claude_acp_descriptor.dart';
import 'codex_acp_descriptor.dart';
import 'grok_descriptor.dart';

/// The shipped ACP agents: data-only adapters, because everything the runtime
/// needs is the descriptor's `acp` spec. No class per agent, so nothing
/// outside this package can name one. Each wears the mark of the agent it
/// drives, or a generic glyph where the app ships no mark.
const claudeAcpAdapter = DataOnlyAgentAdapter(
  claudeAcpDescriptor,
  presentation: AgentPresentation(shortName: 'Claude', mark: AgentMark.claude),
);
const codexAcpAdapter = DataOnlyAgentAdapter(
  codexAcpDescriptor,
  presentation: AgentPresentation(shortName: 'Codex', mark: AgentMark.openAi),
);
const antigravityAcpAdapter = DataOnlyAgentAdapter(
  antigravityAcpDescriptor,
  presentation: AgentPresentation(
    shortName: 'Antigravity',
    mark: AgentMark.antigravity,
  ),
);

/// The public registry publishes an icon per entry for clients to draw; a
/// shipped agent with no mark of the app's own is drawn with it, the glyph
/// standing in until it is fetched.
const grokAdapter = DataOnlyAgentAdapter(
  grokDescriptor,
  presentation: AgentPresentation(
    shortName: 'Grok',
    glyph: AgentGlyph.rocket,
    iconUrl:
        'https://cdn.agentclientprotocol.com/registry/v1/latest/grok-build.svg',
  ),
);
