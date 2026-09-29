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
          ask: PromptAsk.fromJson(json['ask']),
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
    this.ask,
    super.decidedBy,
    super.decidedBySessionId,
  });

  final bool approve;

  /// The prompt the answer was given to, as the card drew it. Null answers
  /// whatever prompt is open when it lands, as an older client's does.
  final PromptAsk? ask;

  /// This answer without [ask], for a server that would not check it.
  ApprovalAnswerRequest withoutAsk() => ApprovalAnswerRequest(
    sessionId: sessionId,
    approve: approve,
    requireOpenPrompt: requireOpenPrompt,
    decidedBy: decidedBy,
    decidedBySessionId: decidedBySessionId,
  );

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
    // Additive: an older server ignores the key and answers as before.
    if (ask case final ask? when ask.names) 'ask': ask.toJson(),
  };
}

/// **Which prompt an approval answers**: what the card was drawn from. An
/// approve delivered late — resent on a resumed link, or tapped on a card
/// already stale — must not land on the prompt that opened after it.
class PromptAsk {
  const PromptAsk({this.waitingSince, this.toolUseId, this.menuId});

  /// [report]'s prompt, and [menu] when the card showed the one on screen.
  factory PromptAsk.drawnFrom(
    AgentStatusReport report, {
    AgentScreenMenu? menu,
  }) => PromptAsk(
    waitingSince: report.waitingSince,
    toolUseId: report.toolAsk?.toolUseId,
    menuId: menu?.id,
  );

  /// When the session began waiting ([AgentStatusReport.waitingSince]).
  final DateTime? waitingSince;

  /// The call the agent's hook said the prompt is about.
  final String? toolUseId;

  /// The menu on screen ([AgentScreenMenu.id]), when the card drew one.
  final String? menuId;

  /// Whether anything names the prompt at all.
  bool get names => waitingSince != null || toolUseId != null || menuId != null;

  /// Whether [open], the status now, may be the prompt this names. Compared
  /// to the millisecond: the value crossed the wire as text.
  bool matches(AgentStatusReport? open) {
    final since = waitingSince;
    if (since != null &&
        open?.waitingSince?.millisecondsSinceEpoch !=
            since.millisecondsSinceEpoch) {
      return false;
    }
    // A card that named its call answers only a prompt about that call: one
    // the status no longer ties to it is some other prompt.
    final call = toolUseId;
    return call == null || call == open?.toolAsk?.toolUseId;
  }

  /// Whether [matches] had anything to compare, beside [menuId].
  bool comparable(AgentStatusReport? open) =>
      waitingSince != null || toolUseId != null;

  Map<String, Object?> toJson() => {
    if (waitingSince case final since?)
      'waitingSince': since.toUtc().toIso8601String(),
    'toolUseId': ?toolUseId,
    'menuId': ?menuId,
  };

  /// Null for no ask, or a shape this build cannot read.
  static PromptAsk? fromJson(Object? json) {
    if (json is! Map) return null;
    final since = json['waitingSince'];
    final toolUseId = json['toolUseId'];
    final menuId = json['menuId'];
    final ask = PromptAsk(
      waitingSince: since is String ? DateTime.tryParse(since) : null,
      toolUseId: toolUseId is String ? toolUseId : null,
      menuId: menuId is String ? menuId : null,
    );
    return ask.names ? ask : null;
  }

  @override
  bool operator ==(Object other) =>
      other is PromptAsk &&
      other.waitingSince?.millisecondsSinceEpoch ==
          waitingSince?.millisecondsSinceEpoch &&
      other.toolUseId == toolUseId &&
      other.menuId == menuId;

  @override
  int get hashCode =>
      Object.hash(waitingSince?.millisecondsSinceEpoch, toolUseId, menuId);
}

/// The refusal of an answer whose prompt has gone.
const String kPromptChangedRefusal =
    'the prompt changed since it was shown, so nothing was pressed';

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
