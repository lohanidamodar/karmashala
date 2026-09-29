import 'package:agent_cli/descriptors.dart';

import '../domain/approval_answer.dart';
import '../domain/prompt_answer_request.dart' show kPromptChangedRefusal;
import '../domain/prompt_refusal.dart';
import 'menu_answerer.dart';

/// **Approve and deny, for every surface that offers them** — the MCP tool and
/// the phone; the desktop card answers a menu by option already.
///
/// When the prompt is a menu the answer is an **option**, found by the words
/// the agent's [AgentMenuSupport] declares affirmative or negative, moved to
/// and confirmed through [SessionMenuAnswerer.choose]. Enter alone confirms
/// whatever is highlighted, and on Claude Code's folder trust that is
/// `No, exit`: "approve" used to quit the agent. A menu with no such option is
/// refused with nothing pressed. Only a prompt that is not a menu — or a deny
/// on a prompt whose cancel the agent declares a safe "no" — presses the key
/// from [AgentApprovalRules], exactly as before.
class SessionApprovalAnswerer {
  SessionApprovalAnswerer({
    required this.menus,
    required this.rulesFor,
    required this.agentNameFor,
    required this.hasOpenQuestion,
    required this.pressAnswerKey,
    required this.recordMenuAnswer,
  });

  final SessionMenuAnswerer menus;

  /// The agent's declared keys for [sessionId], empty when it names none.
  final AgentApprovalRules Function(String sessionId) rulesFor;

  final String Function(String sessionId) agentNameFor;

  /// A question's screen has rows a menu reader would misread as options.
  final bool Function(String sessionId) hasOpenQuestion;

  /// Presses one declared key and records what the agent's table says it
  /// authorised; false without a terminal to press into.
  final bool Function(
    String sessionId,
    String keys, {
    required String decidedBy,
    required String? decidedBySessionId,
  })
  pressAnswerKey;

  /// Records an option chosen on a menu: the keys moved a highlight, so the
  /// key table cannot say what they authorised.
  final void Function(
    String sessionId, {
    required bool granted,
    required String option,
    required String effect,
    required String decidedBy,
    required String? decidedBySessionId,
  })
  recordMenuAnswer;

  /// Answers [sessionId]'s prompt. Throws [SessionPromptRefusal] with nothing
  /// chosen — at worst a highlight moved and left there. With [menuId], the
  /// menu on screen must be that one: the answer was given to it.
  Future<SessionApprovalAnswer> answer(
    String sessionId, {
    required bool approve,
    String? menuId,
    String decidedBy = 'the user',
    String? decidedBySessionId,
  }) async {
    final decision = approve ? 'approve' : 'deny';
    final rules = rulesFor(sessionId);
    final key = approve ? rules.approve : rules.deny;
    final support = menus.supportFor(sessionId);
    var menu = menus.onScreen(sessionId);
    if (menu != null && hasOpenQuestion(sessionId)) menu = null;
    if (menuId != null && menu?.id != menuId) {
      throw const SessionPromptRefusal(kPromptChangedRefusal, stale: true);
    }

    if (menu != null &&
        support != null &&
        !(key != null && !approve && support.cancelDeclinesIn(menu))) {
      final option = approve
          ? support.affirmativeIn(menu)
          : support.negativeIn(menu);
      final offered = menu.options.map((o) => '"$o"').join(', ');
      if (option == null) {
        throw SessionPromptRefusal(
          'The prompt on screen is a menu (${_asked(menu)}; options $offered) '
          'and none of its options is one ${agentNameFor(sessionId)} is known '
          'to mean "$decision", so nothing was pressed — Enter would confirm '
          'whichever is highlighted, "${menu.options[menu.highlighted]}". '
          'Answer it in the terminal.',
        );
      }
      final chosen = await menus.choose(
        sessionId,
        menuId: menu.id,
        option: option,
      );
      final effect =
          'Chose "$chosen" on the menu ${_asked(menu)} (options $offered): '
          'moved the highlight there and pressed Enter. '
          '${agentNameFor(sessionId)} now does what that option says.';
      recordMenuAnswer(
        sessionId,
        granted: approve,
        option: chosen,
        effect: effect,
        decidedBy: decidedBy,
        decidedBySessionId: decidedBySessionId,
      );
      return SessionApprovalAnswer(answered: chosen, effect: effect);
    }

    if (key == null) {
      throw SessionPromptRefusal(
        'this agent names no way to $decision from outside its terminal, so '
        'there is no key to press',
      );
    }
    if (!pressAnswerKey(
      sessionId,
      key.keys,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
    )) {
      throw const SessionPromptRefusal(
        'this session has no live terminal to answer in',
        noTerminal: true,
      );
    }
    return SessionApprovalAnswer(
      answered: key.label,
      effect: menu == null
          ? key.effect
          : '${key.effect} On this menu (${_asked(menu)}) that declines it '
                'and leaves ${agentNameFor(sessionId)} running.',
    );
  }

  /// The row that asks, for a sentence: the last one with a `?` in it (folder
  /// trust wraps its question mid-row), else the last row of the prompt.
  static String _asked(AgentScreenMenu menu) {
    final question = menu.prompt.lastWhere(
      (row) => row.contains('?'),
      orElse: () => menu.prompt.isEmpty ? '' : menu.prompt.last,
    );
    return question.isEmpty ? 'with no prompt' : 'asking "$question"';
  }
}
