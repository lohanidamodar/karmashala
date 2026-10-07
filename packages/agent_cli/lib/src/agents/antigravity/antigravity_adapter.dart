import '../../ask/cli_invocation.dart';
import '../../cli_detection/data/transcript_dialect.dart';
import '../../process/command_runner_factory.dart';
import '../adapter/agent_active_model.dart';
import '../adapter/agent_adapter.dart';
import '../adapter/agent_presentation.dart';
import '../adapter/agent_chat_protocol.dart';
import '../adapter/agent_directory_conversations.dart';
import '../adapter/agent_store.dart';
import '../adapter/agent_transcripts.dart';
import '../adapter/agent_usage_support.dart';
import '../domain/agent_descriptor.dart';
import 'antigravity_active_model.dart';
import 'antigravity_chat_protocol.dart';
import 'antigravity_descriptor.dart';
import 'antigravity_directory_conversations.dart';
import 'antigravity_one_shot.dart';
import 'antigravity_store.dart';
import 'antigravity_transcript.dart';
import 'antigravity_usage_endpoint.dart';

/// **Antigravity CLI (`agy`)**, behind the one boundary: a store that yields
/// identity without content, a conversation id learned after the fact from the
/// directory it ran in, and the quota summary the Antigravity IDE reads. No
/// stats, no file-change record, no pictures, no account
/// switching — each degrades rather than guesses.
class AntigravityAdapter extends AgentAdapter {
  /// [descriptor] is Antigravity's own unless a caller — a test, typically —
  /// describes an agent that behaves like it under another name.
  const AntigravityAdapter({this.descriptor = antigravityDescriptor});

  @override
  final AgentDescriptor descriptor;

  @override
  AgentPresentation get presentation =>
      AgentPresentation.of(descriptor.displayName, mark: AgentMark.antigravity);

  @override
  AgentChatProtocol chatProtocol(RunnerResolver runnerFor) =>
      AntigravityChatProtocol(runnerFor: runnerFor);

  @override
  CliInvocation oneShot(String prompt, {String? systemPrompt, String? model}) =>
      antigravityOneShot(prompt, systemPrompt: systemPrompt, model: model);

  @override
  AgentStore get store => const AntigravityStore();

  /// The store's own conversation file is protobuf; a plain JSONL transcript
  /// sits elsewhere on some installs, so it is found per session and a chat
  /// view is not the default.
  @override
  AgentTranscripts get transcripts => const AgentTranscripts(
    dialect: TranscriptDialect.antigravityJsonl,
    buildsChatView: false,
    redirect: antigravityTranscriptPathFor,
  );

  @override
  AgentActiveModel get activeModel => const AntigravityActiveModel();

  @override
  AgentUsageSupport get usage =>
      const AgentUsageSupport(endpoint: AntigravityUsageEndpoint());

  @override
  AgentDirectoryConversations get directoryConversations =>
      const AntigravityDirectoryConversations();
}
