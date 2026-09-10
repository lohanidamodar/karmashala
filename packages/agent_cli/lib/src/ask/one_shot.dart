import '../agents/data/antigravity_adapter.dart';
import '../agents/data/claude_code_adapter.dart';
import '../agents/data/codex_adapter.dart';
import '../agents/data/generic_agent_adapter.dart';
import '../agents/domain/agent_adapter.dart';
import '../agents/domain/agent_descriptor.dart';
import '../agents/domain/agent_ids.dart';
import '../sessions/session_event_types.dart';

/// How to ask a CLI one question, and how to read its answer.
///
/// Kept as data so adding a CLI is a case here rather than a new code path, and
/// so the arguments can be asserted in tests without running anything.
class CliInvocation {
  const CliInvocation({required this.arguments, required this.parse});

  final List<String> arguments;

  /// Pulls assistant text out of one line of output. Returns null for lines
  /// that carry no text — progress, session banners, usage totals.
  final String? Function(String line) parse;
}

/// Builds the one-shot invocation for [agentId].
///
/// **The mode Karmashala did not have.** Everything else this package does with
/// an agent is a *session*: a process that stays up, is written to and read
/// from, and whose conversation the agent stores. This asks one question and
/// takes one answer.
///
/// [systemPrompt] replaces the CLI's own agent prompt: these are coding agents,
/// and left alone they will happily start reading files and running commands
/// instead of answering. Tools are disabled for the same reason — a voice
/// assistant that edits your repository because you thought aloud is not what
/// anyone asked for.
///
/// The per-agent argv is the public `agent_cli` package's, unchanged. The
/// *parsers* are not: the ones this package already had read a whole event
/// vocabulary out of the same streams, so the text is filtered out of those
/// rather than read a second way (docs/PACKAGE_SPLIT.md §3).
CliInvocation oneShotInvocation(
  String agentId,
  String prompt, {
  String? systemPrompt,
  String? model,
  AgentDescriptor? descriptor,
}) => switch (agentId) {
  AgentIds.claudeCode => CliInvocation(
    arguments: [
      '-p', prompt,
      '--output-format', 'stream-json',
      '--verbose',
      // No tools: answer from the conversation, do not act on it.
      '--allowed-tools', '',
      if (systemPrompt != null) ...['--system-prompt', systemPrompt],
      if (model != null) ...['--model', model],
    ],
    parse: (line) => _text(parseClaudeMessage(line)),
  ),
  AgentIds.codex => CliInvocation(
    arguments: [
      'exec',
      // Codex refuses to run outside a git repository otherwise, and the
      // caller's working directory is not necessarily one.
      '--skip-git-repo-check',
      '--json',
      if (model != null) ...['--model', model],
      if (systemPrompt != null) '$systemPrompt\n\n$prompt' else prompt,
    ],
    parse: (line) {
      final event = parseCodexMessage(line);
      return event == null ? null : _text([event]);
    },
  ),
  AgentIds.antigravity => CliInvocation(
    arguments: [
      '--print',
      if (systemPrompt != null) '$systemPrompt\n\n$prompt' else prompt,
      '--output-format',
      'stream-json',
      if (model != null) ...['--model', model],
    ],
    parse: (line) => _text(parseAntigravityMessage(line)),
  ),
  // Everything else: the descriptor says how it takes a prompt and a model,
  // and its output is plain text. An agent that declares neither is still
  // asked — with the prompt as its only argument — because that is what a CLI
  // with no flags does.
  _ => CliInvocation(
    arguments: _fromDescriptor(descriptor, prompt, systemPrompt, model),
    parse: (line) => _text(parseGenericAgentLine(line)),
  ),
};

List<String> _fromDescriptor(
  AgentDescriptor? descriptor,
  String prompt,
  String? systemPrompt,
  String? model,
) {
  final text = systemPrompt == null ? prompt : '$systemPrompt\n\n$prompt';
  final spec = descriptor?.launch;
  if (spec == null) return [text];
  return [
    ...spec.model.argumentsFor(model),
    ...spec.prompt.isSupported ? spec.prompt.argumentsFor(text) : [text],
  ];
}

/// The assistant text in [events], or null when they carry none.
String? _text(List<AgentEvent> events) {
  final buffer = StringBuffer();
  for (final event in events) {
    if (event.type != SessionEventTypes.agentMessage) continue;
    buffer.write(event.data['text'] ?? '');
  }
  final out = buffer.toString();
  return out.isEmpty ? null : out;
}
