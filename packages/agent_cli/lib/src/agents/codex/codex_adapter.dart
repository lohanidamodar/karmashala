import '../../ask/cli_invocation.dart';
import '../../cli_detection/data/transcript_dialect.dart';
import '../../process/command_runner_factory.dart';
import '../adapter/agent_accounts.dart';
import '../adapter/agent_active_model.dart';
import '../adapter/agent_artifact_markers.dart';
import '../adapter/agent_adapter.dart';
import 'codex_visualize_markers.dart';
import '../adapter/agent_chat_protocol.dart';
import '../adapter/agent_file_changes.dart';
import '../adapter/agent_import_audit.dart';
import '../adapter/agent_media_reader.dart';
import '../adapter/agent_model_lister.dart';
import '../adapter/agent_presentation.dart';
import '../adapter/agent_rewind.dart';
import '../adapter/agent_stats.dart';
import '../adapter/agent_store.dart';
import '../adapter/agent_store_server.dart';
import '../adapter/agent_transcripts.dart';
import '../adapter/agent_usage_support.dart';
import '../adapter/usage_limit_evidence.dart';
import '../domain/agent_descriptor.dart';
import 'codex_chat_protocol.dart';
import 'codex_descriptor.dart';
import 'codex_import_audit.dart';
import 'codex_media_reader.dart';
import 'codex_models_cache.dart';
import 'codex_one_shot.dart';
import 'codex_rate_limit_reader.dart';
import 'codex_stats.dart';
import 'codex_store.dart';
import 'codex_store_reader.dart' show codexInjectedContext;
import 'codex_store_server.dart';
import 'codex_usage_endpoint.dart';

/// **OpenAI Codex CLI**, behind the one boundary: the app-server protocol for
/// chat and for its own thread index, rollout files, and a rate-limit record
/// as the only trace of a usage limit.
class CodexAdapter extends AgentAdapter {
  /// [descriptor] is Codex's own unless a caller — a test, typically —
  /// describes an agent that behaves like Codex under another name.
  const CodexAdapter({this.descriptor = codexDescriptor});

  @override
  final AgentDescriptor descriptor;

  @override
  AgentPresentation get presentation => AgentPresentation.of(
    descriptor.displayName,
    glyph: AgentGlyph.terminal,
    mark: AgentMark.openAi,
  );

  @override
  AgentChatProtocol chatProtocol(RunnerResolver runnerFor) =>
      CodexChatProtocol(runnerFor: runnerFor);

  @override
  CliInvocation oneShot(String prompt, {String? systemPrompt, String? model}) =>
      codexOneShot(prompt, systemPrompt: systemPrompt, model: model);

  @override
  AgentStore get store => const CodexStore();

  @override
  AgentTranscripts get transcripts => const AgentTranscripts(
    dialect: TranscriptDialect.codexRollout,
    injected: codexInjectedContext,
  );

  @override
  AgentStats get stats => const CodexStats();

  /// `thread/turns/list`, from the shared app-server pool.
  @override
  AgentFileChanges get fileChanges => const StoreServerFileChanges();

  @override
  AgentMediaReader get media => const CodexMediaReader();

  @override
  AgentArtifactMarkers get artifactMarkers => const CodexVisualizeMarkers();

  @override
  AgentRewind get rewind => const NoOwnUndo(
    'Codex has no undo of its own: it removed its snapshots in '
    'April 2026. These checkpoints are the way back.',
  );

  @override
  AgentUsageSupport get usage => const AgentUsageSupport(
    endpoint: CodexUsageEndpoint(),
    reportsResetTime: true,
    // Codex persists no error record and fires no failure hook, so its
    // rollout's rate-limit block is the only durable trace of a limit.
    limitEvidence: StateFileRateLimitEvidence(readCodexRateLimits),
  );

  @override
  AgentAccounts get accounts => const OpenAiAuthFileAccounts();

  @override
  AgentStoreServer get storeServer => const CodexStoreServer();

  @override
  AgentModelLister get modelLister => const CodexModelLister();

  @override
  AgentActiveModel get activeModel =>
      const TranscriptActiveModel(TranscriptDialect.codexRollout);

  @override
  AgentImportAudit get importAudit => const CodexImportAudit();
}
