import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/events.dart';

/// Everything [SessionPromptAnswers] needs of whoever holds the terminals:
/// the session host for the sessions it runs, the app for a pane of its own.
/// Each call names a session **row** id.
abstract interface class PromptTerminals {
  /// Whether a session row [sessionId] exists at all.
  bool exists(String sessionId);

  /// The agent the session runs, or null when it is not known.
  AgentDescriptor? agentOf(String sessionId);

  /// What the session's agent is doing now, or null when nothing is known.
  AgentStatusReport? statusOf(String sessionId);

  /// The question the session's agent has open now, or null.
  Future<AgentQuestionSet?> openQuestion(String sessionId);

  /// The bottom `kMenuScreenRows` rows of the session's live terminal, or
  /// null without one.
  List<String>? screen(String sessionId);

  /// Presses [keys] into the session's live terminal; false without one.
  bool press(String sessionId, String keys);

  /// Files an answered prompt in the session's decision record. Best-effort:
  /// never throws.
  void record(DecisionRecord decision);
}
