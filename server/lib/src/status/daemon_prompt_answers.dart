import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_store/database.dart';

import 'package:karmashala_host_protocol/protocol.dart';
import 'daemon_agent_status.dart';
import 'package:karmashala_session_engine/store.dart';

/// **Answering the prompts of the agents this host holds**: approve and deny,
/// a menu's option, a question's answers — typed into the PTY here, read back
/// off this host's own copy of the screen, and filed in the session's
/// decision record. The phone, the desktop app and an agent's
/// `session_answer` all come here for a hosted session, so an answer works
/// the same with the app open or closed.
class DaemonPromptAnswers implements PromptTerminals {
  DaemonPromptAnswers({
    required this.status,
    required AppDatabase database,
    this.agents = AgentRegistry.builtIn,
    Duration menuPoll = const Duration(milliseconds: 100),
    Duration menuPatience = const Duration(seconds: 3),
    this.onDecision,
  }) : _sessions = SessionDao(database),
       _decisions = DecisionRecordDao(database) {
    answers = SessionPromptAnswers(
      terminals: this,
      clock: status.keeper.clock,
      menuPoll: menuPoll,
      menuPatience: menuPatience,
    );
  }

  final DaemonAgentStatus status;
  final AgentRegistry agents;

  /// Told of each decision this files, so every client hears of it on the
  /// data channel.
  void Function(DecisionRecord decision)? onDecision;
  final SessionDao _sessions;
  final DecisionRecordDao _decisions;
  late final SessionPromptAnswers answers;

  /// Whether the row [sessionId]'s session is one this host answers for: it
  /// runs here, and its agent's status is kept.
  bool holds(String sessionId) =>
      status.runningSessionOf(sessionId) != null &&
      status.keeper.isTracked(sessionId);

  /// Answers [request] — `PromptAnswerRequest.toJson` from a client — as the
  /// frame that replies to [requestId].
  Future<PromptAnsweredMessage> answerFrame(
    int requestId,
    Map<String, Object?> request,
  ) async {
    final parsed = PromptAnswerRequest.fromJson(request);
    if (parsed == null) {
      return PromptAnsweredMessage.refused(
        requestId: requestId,
        refusal: PromptRefusalKind.refused,
        message: 'this host cannot read that answer',
      );
    }
    try {
      final answer = await answers.answer(parsed);
      return PromptAnsweredMessage.answered(
        requestId: requestId,
        answered: answer.answered,
        effect: answer.effect,
      );
    } on SessionPromptRefusal catch (refusal) {
      return PromptAnsweredMessage.refused(
        requestId: requestId,
        refusal: refusal.notFound
            ? PromptRefusalKind.notFound
            : refusal.noTerminal
            ? PromptRefusalKind.noTerminal
            : PromptRefusalKind.refused,
        message: refusal.message,
      );
    }
  }

  @override
  bool exists(String sessionId) => _sessions.getById(sessionId) != null;

  @override
  AgentDescriptor? agentOf(String sessionId) {
    final agentId = status.keeper.agentOf(sessionId);
    return agentId == null ? null : agents.byId(agentId);
  }

  @override
  AgentStatusReport? statusOf(String sessionId) =>
      status.statusOf(sessionId)?.report;

  @override
  Future<AgentQuestionSet?> openQuestion(String sessionId) async =>
      status.statusOf(sessionId)?.question;

  @override
  List<String>? screen(String sessionId) =>
      status.runningSessionOf(sessionId)?.tailText(kMenuScreenRows);

  @override
  bool press(String sessionId, String keys) {
    if (keys.isEmpty) return false;
    return status.runningSessionOf(sessionId)?.typeAsHost(utf8.encode(keys)) ??
        false;
  }

  @override
  void record(DecisionRecord decision) {
    try {
      final stored = _decisions.append(decision);
      onDecision?.call(stored);
    } on Object {
      // Best-effort, as the app's recorder is: an answer that landed is not
      // taken back because its record could not be written.
    }
  }
}
