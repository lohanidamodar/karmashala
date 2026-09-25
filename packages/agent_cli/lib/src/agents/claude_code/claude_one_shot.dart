import '../../ask/assistant_text.dart';
import '../../ask/cli_invocation.dart';
import 'claude_code_chat_protocol.dart';

/// One question to Claude Code in print mode, tools off.
CliInvocation claudeOneShot(
  String prompt, {
  String? systemPrompt,
  String? model,
}) => CliInvocation(
  arguments: [
    '-p', prompt,
    '--output-format', 'stream-json',
    '--verbose',
    // No tools: answer from the conversation, do not act on it.
    '--allowed-tools', '',
    if (systemPrompt != null) ...['--system-prompt', systemPrompt],
    if (model != null) ...['--model', model],
  ],
  parse: (line) => assistantTextIn(parseClaudeMessage(line)),
);
