import '../../ask/assistant_text.dart';
import '../../ask/cli_invocation.dart';
import '../domain/agent_descriptor.dart';
import 'generic_chat_protocol.dart';

/// The one-shot invocation for an agent with no protocol of its own: the
/// descriptor says how it takes a prompt and a model, and its output is plain
/// text. An agent that declares neither is still asked — with the prompt as its
/// only argument — because that is what a CLI with no flags does.
CliInvocation genericOneShot(
  AgentDescriptor? descriptor,
  String prompt, {
  String? systemPrompt,
  String? model,
}) {
  final text = systemPrompt == null ? prompt : '$systemPrompt\n\n$prompt';
  final spec = descriptor?.launch;
  return CliInvocation(
    arguments: spec == null
        ? [text]
        : [
            ...spec.model.argumentsFor(model),
            ...spec.prompt.isSupported
                ? spec.prompt.argumentsFor(text)
                : [text],
          ],
    parse: (line) => assistantTextIn(parseGenericAgentLine(line)),
  );
}
