import '../../ask/assistant_text.dart';
import '../../ask/cli_invocation.dart';
import 'antigravity_chat_protocol.dart';

/// One question to `agy --print`, answered as stream-json.
CliInvocation antigravityOneShot(
  String prompt, {
  String? systemPrompt,
  String? model,
}) => CliInvocation(
  arguments: [
    '--print',
    if (systemPrompt != null) '$systemPrompt\n\n$prompt' else prompt,
    '--output-format',
    'stream-json',
    if (model != null) ...['--model', model],
  ],
  parse: (line) => assistantTextIn(parseAntigravityMessage(line)),
);
