import '../../ask/cli_invocation.dart';
import '../../cli_detection/data/transcript_dialect.dart';
import '../../process/command_runner_factory.dart';
import '../adapter/agent_accounts.dart';
import '../adapter/agent_adapter.dart';
import '../adapter/agent_chat_protocol.dart';
import '../adapter/agent_file_changes.dart';
import '../adapter/agent_media_reader.dart';
import '../adapter/agent_model_lister.dart';
import '../adapter/agent_rewind.dart';
import '../adapter/agent_stats.dart';
import '../adapter/agent_store.dart';
import '../adapter/agent_transcripts.dart';
import '../adapter/agent_usage_support.dart';
import '../adapter/usage_limit_evidence.dart';
import '../domain/agent_descriptor.dart';
import 'claude_code_chat_protocol.dart';
import 'claude_code_descriptor.dart';
import 'claude_code_stats.dart';
import 'claude_code_store.dart';
import 'claude_file_edits.dart';
import 'claude_media_reader.dart';
import 'claude_model_list.dart';
import 'claude_one_shot.dart';
import 'claude_rewind.dart';
import 'claude_usage_endpoint.dart';

/// Claude Code's own word, in `StopFailure.error`, for a turn a limit ended.
const String kClaudeRateLimitReason = 'rate_limit';

/// **Anthropic Claude Code**, behind the one boundary: stream-json chat, its
/// per-project JSONL store, OAuth usage, and its own rewind points.
class ClaudeCodeAdapter extends AgentAdapter {
  /// [descriptor] is Claude Code's own unless a caller — a test, typically —
  /// describes an agent that behaves like Claude Code under another name.
  const ClaudeCodeAdapter({this.descriptor = claudeCodeDescriptor});

  @override
  final AgentDescriptor descriptor;

  @override
  List<String> get aliases => const ['claude', 'claude code'];

  @override
  AgentChatProtocol chatProtocol(RunnerResolver runnerFor) =>
      ClaudeCodeChatProtocol(runnerFor: runnerFor);

  @override
  CliInvocation oneShot(String prompt, {String? systemPrompt, String? model}) =>
      claudeOneShot(prompt, systemPrompt: systemPrompt, model: model);

  @override
  AgentStore get store => const ClaudeCodeStore();

  @override
  AgentTranscripts get transcripts =>
      const AgentTranscripts(dialect: TranscriptDialect.claudeJsonl);

  @override
  AgentStats get stats => const ClaudeCodeStats();

  @override
  AgentFileChanges get fileChanges =>
      const TranscriptFileEdits(claudeFileEdits);

  @override
  AgentMediaReader get media => const ClaudeMediaReader();

  @override
  AgentRewind get rewind => claudeRewind;

  @override
  AgentUsageSupport get usage => const AgentUsageSupport(
    endpoint: ClaudeUsageEndpoint(),
    reportsResetTime: true,
    // `rate_limit` is also a passing 429. Only a spent window makes it a
    // usage limit, and only a reading names the reset.
    limitEvidence: HookFailureReasonEvidence(kClaudeRateLimitReason),
  );

  @override
  AgentAccounts get accounts => const AnthropicOAuthAccounts();

  @override
  AgentModelLister get modelLister => const ClaudeModelLister();
}
