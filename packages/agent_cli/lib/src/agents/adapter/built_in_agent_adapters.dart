import '../acp/acp_agents.dart';
import '../acp/claude_acp_descriptor.dart';
import '../acp/codex_acp_descriptor.dart';
import '../acp/gemini_cli_descriptor.dart';
import '../acp/grok_descriptor.dart';
import '../antigravity/antigravity_adapter.dart';
import '../antigravity/antigravity_descriptor.dart';
import '../claude_code/claude_code_adapter.dart';
import '../claude_code/claude_code_descriptor.dart';
import '../codex/codex_adapter.dart';
import '../codex/codex_descriptor.dart';
import 'agent_adapter.dart';
import '../domain/agent_descriptor.dart';

/// The agents Karmashala ships.
///
/// Order matters: it is the order agents are probed and listed in. The three
/// terminal agents come first, then the ACP ones.
const List<AgentAdapter> builtInAgentAdapters = [
  ClaudeCodeAdapter(),
  CodexAdapter(),
  AntigravityAdapter(),
  claudeAcpAdapter,
  codexAcpAdapter,
  geminiCliAdapter,
  grokAdapter,
];

/// The shipped agents' descriptors, in [builtInAgentAdapters] order — for a
/// caller that needs only the data, such as a test composing a registry with
/// one of them described differently.
const List<AgentDescriptor> builtInAgentDescriptors = [
  claudeCodeDescriptor,
  codexDescriptor,
  antigravityDescriptor,
  claudeAcpDescriptor,
  codexAcpDescriptor,
  geminiCliDescriptor,
  grokDescriptor,
];
