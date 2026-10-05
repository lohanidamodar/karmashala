import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/util.dart';

import '../domain/approval_answer.dart';
import '../domain/approval_decision.dart';
import '../domain/prompt_answer_request.dart';
import '../domain/prompt_evidence.dart';
import '../domain/prompt_refusal.dart';
import 'approval_answerer.dart';
import 'key_pacer.dart';
import 'menu_answerer.dart';
import 'prompt_answering.dart';
import 'prompt_terminals.dart';
import 'question_typist.dart';

/// **Every answer to an agent's prompt, and the one rule they all turn on** — a
/// key may be offered, and pressed, only for a wait a status source identified
/// as a prompt; a question is answered only while it is the one the answer
/// names. The phone, the desktop card and `session_answer` all come here,
/// through whoever holds the session's terminal: the session host for the
/// sessions it runs, the app for a pane of its own.
///
/// Throws [SessionPromptRefusal], with nothing chosen, when it will not.
class SessionPromptAnswers implements PromptAnswering {
  SessionPromptAnswers({
    required this.terminals,
    this.clock = const SystemClock(),
    Duration menuPoll = const Duration(milliseconds: 100),
    Duration menuPatience = const Duration(seconds: 3),
    SessionQuestionTypist? typist,
    SessionKeyPacer? pacer,
  }) : menus = SessionMenuAnswerer(
         readScreen: terminals.screen,
         supportFor: (sessionId) => terminals.agentOf(sessionId)?.menus,
         isAsking: (sessionId) =>
             terminals.statusOf(sessionId)?.hasOpenPrompt ?? false,
         press: terminals.press,
         poll: menuPoll,
         patience: menuPatience,
       ),
       typist =
           typist ??
           SessionQuestionTypist(
             readScreen: terminals.screen,
             press: terminals.press,
           ),
       pacer = pacer ?? SessionKeyPacer(press: terminals.press);

  final PromptTerminals terminals;
  final Clock clock;
  final SessionMenuAnswerer menus;
  final SessionQuestionTypist typist;
  final SessionKeyPacer pacer;

  late final SessionApprovalAnswerer _approvals = SessionApprovalAnswerer(
    menus: menus,
    rulesFor: (sessionId) =>
        terminals.agentOf(sessionId)?.approval ?? const AgentApprovalRules(),
    agentNameFor: (sessionId) =>
        terminals.agentOf(sessionId)?.displayName ?? 'The agent',
    hasOpenQuestion: (sessionId) =>
        terminals.statusOf(sessionId)?.hasOpenQuestion ?? false,
    pressAnswerKey: _pressAnswerKey,
    recordMenuAnswer: _recordMenuAnswer,
  );

  /// Answers [request]: what was chosen, and what that does to the agent.
  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) =>
      switch (request) {
        ApprovalAnswerRequest() => _approve(request),
        MenuAnswerRequest() => _chooseMenu(request),
        QuestionAnswerRequest() => _answerQuestion(request),
      };

  /// What [sessionId]'s open prompt looks like now, answered by exactly one of
  /// its question, its menu or the agent's keys.
  @override
  Future<PromptEvidence> evidence(String sessionId) async {
    final agent = terminals.agentOf(sessionId);
    final report = terminals.statusOf(sessionId);
    final answerable = report?.hasOpenPrompt ?? false;
    final question = report?.hasOpenQuestion == true && agent != null
        ? await terminals.openQuestion(sessionId)
        : null;
    final menu = answerable ? menus.read(sessionId) : null;
    final rules = agent?.approval;
    return PromptEvidence(
      report: report,
      question: question,
      menu: menu,
      approve: answerable && menu == null ? rules?.approve : null,
      deny: answerable && menu == null ? rules?.deny : null,
    );
  }

  /// The menu open in [sessionId] now, by its status and its screen.
  @override
  AgentScreenMenu? menuOnScreen(String sessionId) => menus.read(sessionId);

  Future<SessionApprovalAnswer> _approve(ApprovalAnswerRequest request) async {
    final sessionId = _existing(request.sessionId);
    final decision = request.approve ? 'approve' : 'deny';
    final agent = terminals.agentOf(sessionId);
    final rules = agent?.approval ?? const AgentApprovalRules();
    final key = request.approve ? rules.approve : rules.deny;
    // Neither a key nor a menu reader: nothing could answer this from here.
    if (key == null && agent?.menus == null) {
      throw SessionPromptRefusal(
        'this agent names no way to $decision from outside its terminal',
      );
    }
    if (request.requireOpenPrompt && !_hasOpenPrompt(sessionId)) {
      throw const SessionPromptRefusal(
        'this session has no prompt open to answer',
      );
    }
    final ask = request.ask;
    final open = terminals.statusOf(sessionId);
    if (ask != null && !ask.matches(open)) {
      throw const SessionPromptRefusal(kPromptChangedRefusal, stale: true);
    }
    final answer = await _approvals.answer(
      sessionId,
      approve: request.approve,
      menuId: ask?.menuId,
      decidedBy: request.decidedBy,
      decidedBySessionId: request.decidedBySessionId,
    );
    // An ask with nothing this status could check it against answered the
    // prompt open now, as an answer without one does: said, not hidden.
    if (ask == null || ask.menuId != null || ask.comparable(open)) {
      return answer;
    }
    return SessionApprovalAnswer(
      answered: answer.answered,
      effect:
          '${answer.effect} The status named no prompt to check this '
          'answer against, so it answered the one open now.',
    );
  }

  Future<SessionApprovalAnswer> _chooseMenu(MenuAnswerRequest request) async {
    final sessionId = _existing(request.sessionId);
    if (!_hasOpenPrompt(sessionId)) {
      throw const SessionPromptRefusal(
        'this session has no prompt open to answer',
      );
    }
    final menu = menus.onScreen(sessionId);
    final chosen = await menus.choose(
      sessionId,
      menuId: request.menuId,
      option: request.option,
    );
    final effect =
        'Chose "$chosen" on the menu'
        '${menu == null ? '' : ' (options ${menu.options.map((o) => '"$o"').join(', ')})'}'
        ': moved the highlight there and pressed Enter.';
    return SessionApprovalAnswer(answered: chosen, effect: effect);
  }

  Future<SessionApprovalAnswer> _answerQuestion(
    QuestionAnswerRequest request,
  ) async {
    final sessionId = _existing(request.sessionId);
    final support = terminals.agentOf(sessionId)?.questions;
    if (support == null) {
      throw const SessionPromptRefusal(
        "this agent's questions can only be answered in its terminal",
      );
    }
    if (!(terminals.statusOf(sessionId)?.hasOpenQuestion ?? false)) {
      throw const SessionPromptRefusal(
        'this session has no question open to answer',
      );
    }
    final open = await terminals.openQuestion(sessionId);
    // Neither case proves anybody answered it, so neither says so.
    if (open == null) {
      throw const SessionPromptRefusal(
        'no question could be read in this session now, so nothing was '
        'answered',
      );
    }
    if (open.toolUseId != request.toolUseId) {
      throw const SessionPromptRefusal(
        'the question changed since it was shown, so nothing was answered',
      );
    }
    if (request.decline) {
      if (!await pacer.type(sessionId, support.declineKeys)) {
        throw const SessionPromptRefusal(
          'this session has no live terminal to answer in',
          noTerminal: true,
        );
      }
      return const SessionApprovalAnswer(
        answered: 'declined',
        effect: 'Dismissed the question without answering it.',
      );
    }
    if (request.chat) {
      final row = support.chatRow;
      if (row == null) {
        throw const SessionPromptRefusal(
          "this agent's questions offer no way to talk them over",
        );
      }
      await typist.chatAbout(sessionId, open, row);
      return SessionApprovalAnswer(
        answered: row,
        effect: 'Left the question to talk it over.',
      );
    }
    try {
      // The measured keys double as the check that the answer fits at all,
      // before a single key is pressed.
      support.keysFor(open, request.answers);
    } on ArgumentError catch (error) {
      throw SessionPromptRefusal('${error.message}');
    }
    await typist.answer(sessionId, open, request.answers);
    return const SessionApprovalAnswer(
      answered: 'answered',
      effect: 'Answered the question with the options chosen.',
    );
  }

  String _existing(String sessionId) {
    if (!terminals.exists(sessionId)) {
      throw const SessionPromptRefusal('no such session', notFound: true);
    }
    return sessionId;
  }

  /// The one rule, kept on [AgentStatusReport.hasOpenPrompt] because
  /// `session_send` refuses on it too. Absent is not an open prompt.
  bool _hasOpenPrompt(String sessionId) =>
      terminals.statusOf(sessionId)?.hasOpenPrompt ?? false;

  /// Presses one declared key and files what the agent's own table says it
  /// authorised — a table lookup, not an interpretation: a keystroke matching
  /// neither answer records nothing.
  bool _pressAnswerKey(
    String sessionId,
    String keys, {
    required String decidedBy,
    required String? decidedBySessionId,
  }) {
    if (keys.isEmpty || !terminals.press(sessionId, keys)) return false;
    final rules =
        terminals.agentOf(sessionId)?.approval ?? const AgentApprovalRules();
    final granted = rules.approve?.keys == keys;
    final key = granted ? rules.approve : rules.deny;
    if (key == null || key.keys != keys) return true;
    _file(
      sessionId,
      granted: granted,
      effect: key.effect,
      label: key.label,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
    );
    return true;
  }

  /// A menu's option was chosen: the keys moved a highlight, so the key table
  /// cannot say what they authorised — the option's words do.
  void _recordMenuAnswer(
    String sessionId, {
    required bool granted,
    required String option,
    required String effect,
    required String decidedBy,
    required String? decidedBySessionId,
  }) => _file(
    sessionId,
    granted: granted,
    effect: effect,
    label: option,
    decidedBy: decidedBy,
    decidedBySessionId: decidedBySessionId,
  );

  void _file(
    String sessionId, {
    required bool granted,
    required String effect,
    required String label,
    required String decidedBy,
    required String? decidedBySessionId,
  }) {
    final record = approvalDecisionRecord(
      sessionId: sessionId,
      granted: granted,
      effect: effect,
      answerLabel: label,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
      recordedAt: clock.nowUtc(),
    );
    if (record != null) terminals.record(record);
  }
}
