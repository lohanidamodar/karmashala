import 'package:agent_cli/descriptors.dart';

/// What one session's open prompt looks like now, for a surface that offers
/// answers to it: the status that says a prompt is open, and exactly one way
/// to answer — the question, the menu, or the agent's declared keys.
class PromptEvidence {
  const PromptEvidence({
    this.report,
    this.question,
    this.menu,
    this.approve,
    this.deny,
  });

  /// The session's status, or null when nothing is known of it.
  final AgentStatusReport? report;

  /// The open question, travelling whole and never with approve/deny beside
  /// it.
  final AgentQuestionSet? question;

  /// A menu read off the screen, answered by option: Enter chooses whatever
  /// is highlighted, which on a folder-trust prompt is "No, exit".
  final AgentScreenMenu? menu;

  /// The agent's declared keys, only for a prompt a source could see that is
  /// not a menu: `awaitingApproval` is also true of an agent at its own input,
  /// where approve would type Enter.
  final AgentApprovalKey? approve;
  final AgentApprovalKey? deny;

  /// Whether the report says the agent stopped for the user at all.
  bool get asking => report?.status == AgentActivityStatus.awaitingApproval;
}
