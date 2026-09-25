import 'package:agent_cli/descriptors.dart';

/// One answer to a prompt an agent has open, whoever asked for it — the phone,
/// the desktop card, an agent's `session_answer` — as the session host is
/// asked to type it. Each carries what it must still match when it lands, so
/// an answer meant for one prompt cannot land on the next.
sealed class PromptAnswerRequest {
  const PromptAnswerRequest({
    required this.sessionId,
    this.decidedBy = 'the user',
    this.decidedBySessionId,
  });

  /// The session row.
  final String sessionId;

  /// Who decided, for the decision record: "the user", "an agent in session
  /// …". Read by somebody who was not there.
  final String decidedBy;
  final String? decidedBySessionId;

  Map<String, Object?> toJson();

  Map<String, Object?> _common(String kind) => {
    'kind': kind,
    'sessionId': sessionId,
    'decidedBy': decidedBy,
    'decidedBySessionId': ?decidedBySessionId,
  };

  /// Null for a shape this build cannot read.
  static PromptAnswerRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final sessionId = json['sessionId'];
    if (sessionId is! String) return null;
    final decidedBy = json['decidedBy'] as String? ?? 'the user';
    final decidedBySessionId = json['decidedBySessionId'] as String?;
    switch (json['kind']) {
      case 'approval':
        final approve = json['approve'];
        if (approve is! bool) return null;
        return ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: approve,
          requireOpenPrompt: json['requireOpenPrompt'] != false,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
      case 'menu':
        final menuId = json['menuId'];
        final option = json['option'];
        if (menuId is! String || option is! int) return null;
        return MenuAnswerRequest(
          sessionId: sessionId,
          menuId: menuId,
          option: option,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
      case 'question':
        final toolUseId = json['toolUseId'];
        final answers = json['answers'];
        if (toolUseId is! String || answers is! List) return null;
        return QuestionAnswerRequest(
          sessionId: sessionId,
          toolUseId: toolUseId,
          decline: json['decline'] == true,
          answers: [
            for (final answer in answers)
              if (answer is Map && answer['text'] is String)
                AgentQuestionAnswer.text(answer['text'] as String)
              else if (answer is Map && answer['options'] is List)
                AgentQuestionAnswer.options(
                  (answer['options'] as List).whereType<int>().toList(),
                ),
          ],
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
    }
    return null;
  }
}

/// Approve or deny: a menu by the option the agent's adapter declares
/// affirmative or negative, anything else by its declared key.
class ApprovalAnswerRequest extends PromptAnswerRequest {
  const ApprovalAnswerRequest({
    required super.sessionId,
    required this.approve,
    this.requireOpenPrompt = true,
    super.decidedBy,
    super.decidedBySessionId,
  });

  final bool approve;

  /// Refused unless the session's status says a prompt is open — a phone
  /// holding a stale card must not type Enter into a session that has merely
  /// finished its turn. `session_answer` answers what is on the screen and
  /// passes false: its caller has read the screen, and the menu reader and
  /// the question guard still stand.
  final bool requireOpenPrompt;

  @override
  Map<String, Object?> toJson() => {
    ..._common('approval'),
    'approve': approve,
    'requireOpenPrompt': requireOpenPrompt,
  };
}

/// One option of the menu named [menuId], which must still be the one drawn.
class MenuAnswerRequest extends PromptAnswerRequest {
  const MenuAnswerRequest({
    required super.sessionId,
    required this.menuId,
    required this.option,
    super.decidedBy,
    super.decidedBySessionId,
  });

  final String menuId;
  final int option;

  @override
  Map<String, Object?> toJson() => {
    ..._common('menu'),
    'menuId': menuId,
    'option': option,
  };
}

/// Answers — or declines — the question the call [toolUseId] opened.
class QuestionAnswerRequest extends PromptAnswerRequest {
  const QuestionAnswerRequest({
    required super.sessionId,
    required this.toolUseId,
    required this.answers,
    this.decline = false,
    super.decidedBy,
    super.decidedBySessionId,
  });

  final String toolUseId;
  final List<AgentQuestionAnswer> answers;
  final bool decline;

  @override
  Map<String, Object?> toJson() => {
    ..._common('question'),
    'toolUseId': toolUseId,
    'decline': decline,
    'answers': [
      for (final answer in answers)
        answer.text != null
            ? {'text': answer.text}
            : {'options': answer.chosen},
    ],
  };
}
