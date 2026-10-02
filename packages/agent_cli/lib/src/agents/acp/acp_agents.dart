import '../adapter/data_only_agent_adapter.dart';
import 'claude_acp_descriptor.dart';
import 'codex_acp_descriptor.dart';
import 'gemini_cli_descriptor.dart';
import 'grok_descriptor.dart';

/// The shipped ACP agents: data-only adapters, because everything the runtime
/// needs is the descriptor's `acp` spec. No class per agent, so nothing
/// outside this package can name one.
const claudeAcpAdapter = DataOnlyAgentAdapter(claudeAcpDescriptor);
const codexAcpAdapter = DataOnlyAgentAdapter(codexAcpDescriptor);
const geminiCliAdapter = DataOnlyAgentAdapter(geminiCliDescriptor);
const grokAdapter = DataOnlyAgentAdapter(grokDescriptor);
