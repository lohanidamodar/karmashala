import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import '../mcp/mcp_tool_relay.dart';
import 'daemon_prompt_answers.dart';

/// `session_answer` for a session this host holds, answered here rather than
/// forwarded to the app — so an agent can answer another agent's prompt with
/// the app closed. Null for any other tool, or a session the host does not
/// hold, which goes to the app as before. The words are the app's own.
Future<Object?>? sessionAnswerTool(
  DaemonPromptAnswers prompts,
  String tool,
  Map<String, dynamic> arguments,
  String? callerSessionId,
) {
  if (tool != 'session_answer') return null;
  final named = (arguments['sessionId'] as String?)?.trim();
  final sessionId = named != null && named.isNotEmpty ? named : callerSessionId;
  if (sessionId == null || !prompts.holds(sessionId)) return null;
  final decision = arguments['decision'];
  if (decision != 'approve' && decision != 'deny') {
    return Future.error(
      const McpToolRelayFailure("decision must be 'approve' or 'deny'."),
    );
  }
  return prompts.answers
      .answer(
        ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: decision == 'approve',
          // The caller read the screen; the menu reader and the question
          // guard still stand between it and a blind Enter.
          requireOpenPrompt: false,
          // Named rather than left to default to "the user": the decision
          // record this lands in is read by somebody who was not there.
          decidedBy: callerSessionId == null
              ? 'an agent through the MCP bridge'
              : 'an agent in session $callerSessionId',
          decidedBySessionId: callerSessionId,
        ),
      )
      .then<Object?>(
        (answer) => <String, Object?>{
          'sessionId': sessionId,
          'answered': answer.answered,
          'effect': answer.effect,
        },
        onError: (Object error) {
          if (error is! SessionPromptRefusal) throw error;
          final message = error.message;
          throw McpToolRelayFailure(
            '${message[0].toUpperCase()}${message.substring(1)}'
            '${message.endsWith('.') ? '' : '.'} Answer it in the pane.',
          );
        },
      );
}
