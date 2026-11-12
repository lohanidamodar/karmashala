import '../../ask/assistant_text.dart';
import '../../ask/cli_invocation.dart';
import '../domain/agent_descriptor.dart';
import 'codex_chat_protocol.dart';

/// One question to `codex exec`, answered as JSON events.
CliInvocation codexOneShot(
  String prompt, {
  String? systemPrompt,
  String? model,
}) => CliInvocation(
  arguments: [
    'exec',
    // Codex refuses to run outside a git repository otherwise, and the
    // caller's working directory is not necessarily one.
    '--skip-git-repo-check',
    '--json',
    if (model != null) ...['--model', model],
    ...AgentPromptSupport.asPositional(
      systemPrompt != null ? '$systemPrompt\n\n$prompt' : prompt,
    ),
  ],
  parse: (line) {
    final event = parseCodexMessage(line);
    return event == null ? null : assistantTextIn([event]);
  },
);
