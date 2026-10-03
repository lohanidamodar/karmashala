import '../../ask/cli_invocation.dart';
import '../../process/command_runner_factory.dart';
import '../domain/agent_descriptor.dart';
import 'agent_accounts.dart';
import 'agent_chat_protocol.dart';
import 'agent_directory_conversations.dart';
import 'agent_file_changes.dart';
import 'agent_import_audit.dart';
import 'agent_media_reader.dart';
import 'agent_model_lister.dart';
import 'agent_presentation.dart';
import 'agent_rewind.dart';
import 'agent_stats.dart';
import 'agent_store.dart';
import 'agent_store_server.dart';
import 'agent_transcripts.dart';
import 'agent_usage_support.dart';
import 'generic_chat_protocol.dart';
import 'generic_one_shot.dart';

/// **Everything agent-specific about one coding agent, behind one boundary.**
///
/// The daemon, the session engine and the app ask an adapter, never an agent
/// id. Adding an agent — Pi, Cursor, whatever comes next — is one adapter in
/// its own folder under `agents/<agent>/`, registered in an `AgentRegistry`,
/// and nothing else.
///
/// Two halves:
///
/// * [descriptor] — what the agent *is*, as data: binaries, launch and resume
///   vocabulary, hook spec, screen rules, permission and model vocabulary.
/// * the **capabilities** below — what the agent can *do* that needs code. Each
///   is `null` (or a "none" value) when the agent lacks it, and every caller
///   branches on the capability rather than on who the agent is, so an agent
///   with fewer features degrades rather than breaks. The defaults here are
///   exactly that degraded agent: launched from its descriptor, streamed as
///   plain text, asked one question with its prompt as the argument, and
///   nothing else. [DataOnlyAgentAdapter] is that agent.
///
/// Nothing here imports Flutter or an app service. Where a capability needs
/// the host — a SQLite binding, a runner, the host's environment — it takes it
/// as an argument, and the thin glue that supplies it lives in the app,
/// reached through the adapter rather than the id.
abstract class AgentAdapter {
  const AgentAdapter();

  /// What this agent is, as data.
  AgentDescriptor get descriptor;

  /// The agent's identity everywhere: discovery, persistence, settings,
  /// sessions, the MCP control server.
  String get id => descriptor.id;

  /// How the agent is drawn where a name alone is too long or too plain.
  AgentPresentation get presentation =>
      AgentPresentation.of(descriptor.displayName);

  /// Other names a caller may write for this agent (an MCP `cli` argument, a
  /// command line), lowercased. The id itself always matches.
  List<String> get aliases => const [];

  /// How a structured conversation with the agent is carried: a process that
  /// stays up, written to and read from.
  ///
  /// The default launches the CLI from its descriptor and streams its output
  /// as plain text — no tool calls, no structured errors — because there is no
  /// protocol to read. An agent with a real one overrides this.
  AgentChatProtocol chatProtocol(RunnerResolver runnerFor) =>
      GenericChatProtocol(
        agentId: id,
        launch: descriptor.launch,
        runnerFor: runnerFor,
      );

  /// How to ask the agent one question and read its answer.
  ///
  /// The default passes the prompt the way the descriptor declares, or as the
  /// only argument, and reads the output as plain text.
  CliInvocation oneShot(String prompt, {String? systemPrompt, String? model}) =>
      genericOneShot(
        descriptor,
        prompt,
        systemPrompt: systemPrompt,
        model: model,
      );

  /// How the agent is driven over the Agent Client Protocol, or null for a
  /// terminal program. Consumers branch on this, never on [id].
  AcpLaunchSpec? get acp => descriptor.acp;

  /// The agent's own conversation store — sessions, presence, rename and
  /// delete — or null when it keeps none this package can read.
  AgentStore? get store => null;

  /// How the agent's transcripts are read, or null when it writes none this
  /// package can parse.
  AgentTranscripts? get transcripts => null;

  /// Token and turn accounting read from the agent's own records, or null.
  AgentStats? get stats => null;

  /// Where the agent records which files it changed, or null for none.
  AgentFileChanges? get fileChanges => null;

  /// How pictures are found in the agent's transcript, or null.
  AgentMediaReader? get media => null;

  /// What the agent's own undo offers beside Karmashala's checkpoints.
  AgentRewind get rewind => const AgentRewind.unknown();

  /// The agent's usage endpoint and what its limits look like, or null when
  /// the app has no usage endpoint for it.
  AgentUsageSupport? get usage => null;

  /// Which account switching the app offers for this agent, or null.
  AgentAccounts? get accounts => null;

  /// A server process the CLI offers over its own store (listing, renaming,
  /// file changes), or null.
  AgentStoreServer? get storeServer => null;

  /// A store that records the last conversation per directory rather than
  /// taking an id at launch, or null.
  AgentDirectoryConversations? get directoryConversations => null;

  /// How the CLI reports the models this account may use, or null.
  AgentModelLister? get modelLister => null;

  /// How records an older import took that were not conversations are told
  /// apart, or null when every record this agent's store keeps is one.
  AgentImportAudit? get importAudit => null;

  @override
  String toString() => 'AgentAdapter($id)';
}
