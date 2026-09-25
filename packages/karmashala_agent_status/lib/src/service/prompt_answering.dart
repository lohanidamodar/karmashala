import 'package:agent_cli/descriptors.dart';

import '../domain/approval_answer.dart';
import '../domain/prompt_answer_request.dart';
import '../domain/prompt_evidence.dart';

/// Whatever answers a session's prompts for a surface: [SessionPromptAnswers]
/// over the terminals it holds, or a client that asks the session host for
/// the sessions the host holds. The surfaces — the phone's bindings, the
/// desktop card, `session_answer` — never know which.
abstract interface class PromptAnswering {
  /// Answers [request]. Throws `SessionPromptRefusal`, with nothing chosen,
  /// when it will not.
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request);

  /// What [sessionId]'s open prompt looks like now.
  Future<PromptEvidence> evidence(String sessionId);

  /// The menu open in [sessionId] now, or null.
  AgentScreenMenu? menuOnScreen(String sessionId);
}
