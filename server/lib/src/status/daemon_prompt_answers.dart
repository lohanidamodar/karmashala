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
  /// runs here — a PTY or an ACP runtime — and its agent's status is kept.
  bool holds(String sessionId) =>
      status.runsHere(sessionId) && status.keeper.isTracked(sessionId);

  /// Answers [request]: a permission an agent spoken to over ACP has open is
  /// answered over its protocol, anything else typed into its terminal.
  /// Throws [SessionPromptRefusal], with nothing chosen, when it will not.
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) async {
    final runtime = status.acpRuntimeOf(request.sessionId);
    if (runtime == null) {
      if (request is ApprovalAnswerRequest && request.optionId != null) {
        throw const SessionPromptRefusal(
          'only an agent spoken to over ACP names its own options; answer '
          'this prompt with approve or deny',
        );
      }
      return answers.answer(request);
    }
    if (!exists(request.sessionId)) {
      throw const SessionPromptRefusal('no such session', notFound: true);
    }
    final answered = await switch (request) {
      QuestionAnswerRequest(chat: true) => throw const SessionPromptRefusal(
        "this agent's questions offer no way to talk them over",
      ),
      // Declined: left to the person's next message, as the agent offers.
      QuestionAnswerRequest(decline: true, :final toolUseId) =>
        runtime.answerPermission(approve: false, toolCallId: toolUseId),
      QuestionAnswerRequest(:final toolUseId, :final answers) =>
        runtime.answerQuestion(toolUseId: toolUseId, answers: answers),
      ApprovalAnswerRequest() => runtime.answerPermission(
        approve: request.approve,
        toolCallId: request.ask?.toolUseId,
        optionId: request.optionId,
      ),
      MenuAnswerRequest() => throw const SessionPromptRefusal(
        'an agent spoken to over ACP has no menu to answer; approve or deny '
        'its permission request',
      ),
    };
    final filed = approvalDecisionRecord(
      sessionId: request.sessionId,
      granted: answered.granted,
      effect: answered.effect,
      answerLabel: answered.answered,
      decidedBy: request.decidedBy,
      decidedBySessionId: request.decidedBySessionId,
      recordedAt: status.keeper.clock.nowUtc(),
    );
    if (filed != null) record(filed);
    return SessionApprovalAnswer(
      answered: answered.answered,
      effect: answered.effect,
    );
  }

  /// [answer] and [evidence] as the one interface the phone's bindings take.
  PromptAnswering get answering => _Answering(this);

  /// What [sessionId]'s open prompt looks like: an ACP permission request is
  /// answered by [answer], so its evidence names Allow and Reject as the
  /// keys; a terminal's is the screen's.
  Future<PromptEvidence> evidence(String sessionId) async {
    final runtime = status.acpRuntimeOf(sessionId);
    final report = statusOf(sessionId);
    if (runtime == null || !runtime.hasOpenPermission) {
      return answers.evidence(sessionId);
    }
    return PromptEvidence(
      report: report,
      approve: const AgentApprovalKey(
        keys: 'allow',
        label: 'Allow',
        effect: 'Lets the agent make this call.',
      ),
      deny: const AgentApprovalKey(
        keys: 'reject',
        label: 'Reject',
        effect: 'Refuses this call; the agent carries on without it.',
      ),
    );
  }

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
      final answer = await this.answer(parsed);
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

  /// Reads [sessionId]'s open question off its agent's record, for one no
  /// hook carried: a probe has none, and a screen that moved after the hook
  /// makes the grid the status's word, which drops the hook's question.
  Future<AgentQuestionSet?> Function(String sessionId)? readQuestion;

  @override
  Future<AgentQuestionSet?> openQuestion(String sessionId) async =>
      status.statusOf(sessionId)?.question ??
      await readQuestion?.call(sessionId);

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

final class _Answering implements PromptAnswering {
  const _Answering(this._prompts);

  final DaemonPromptAnswers _prompts;

  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) =>
      _prompts.answer(request);

  @override
  Future<PromptEvidence> evidence(String sessionId) =>
      _prompts.evidence(sessionId);

  @override
  AgentScreenMenu? menuOnScreen(String sessionId) =>
      _prompts.answers.menuOnScreen(sessionId);
}
