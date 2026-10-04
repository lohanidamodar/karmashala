import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

/// A phone's approval, question and menu calls, answered by a
/// [PromptAnswering] and shaped as the companion wire carries them — the one
/// mapping, whether the session host answers for a session it holds or the
/// app for a pane of its own.
class CompanionPrompts {
  const CompanionPrompts(this.answers);

  final PromptAnswering answers;

  /// `approval.answer`: what was chosen, in the agent's own words.
  Future<String> answerApproval(String sessionId, String decision) async {
    if (decision != 'approve' && decision != 'deny') {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        "decision must be 'approve' or 'deny'",
      );
    }
    final answer = await _refused(
      () => answers.answer(
        ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: decision == 'approve',
        ),
      ),
    );
    return answer.answered;
  }

  /// `question.answer`: `answered`, or `declined`.
  Future<String> answerQuestion(RemoteQuestionAnswerRequest request) async {
    final answer = await _refused(
      () => answers.answer(
        QuestionAnswerRequest(
          sessionId: request.sessionId,
          toolUseId: request.toolUseId,
          decline: request.decline,
          chat: request.chat,
          answers: [
            for (final answer in request.answers)
              answer.text != null
                  ? AgentQuestionAnswer.text(answer.text!)
                  : AgentQuestionAnswer.options(answer.options),
          ],
        ),
      ),
    );
    return answer.answered;
  }

  /// `menu.answer`: the option chosen, in the agent's own words.
  Future<String> answerMenu(RemoteMenuAnswerRequest request) async {
    final answer = await _refused(
      () => answers.answer(
        MenuAnswerRequest(
          sessionId: request.sessionId,
          menuId: request.menuId,
          option: request.option,
        ),
      ),
    );
    return answer.answered;
  }

  /// `approval.evidence`: the prompt, and exactly one way to answer it.
  Future<RemoteApprovalRequest> approvalEvidence(String sessionId) async {
    final evidence = await answers.evidence(sessionId);
    final report = evidence.report;
    final asking = evidence.asking;
    return RemoteApprovalRequest(
      question: evidence.question == null
          ? null
          : remoteQuestionOf(evidence.question!),
      menu: evidence.menu == null ? null : remoteMenuOf(evidence.menu!),
      sessionId: sessionId,
      evidence: asking ? report!.evidence : const [],
      waiting: asking
          ? remoteWaitOf(report!.waiting)
          : RemoteWaitKind.unrecorded,
      approveLabel: evidence.approve?.label,
      denyLabel: evidence.deny?.label,
    );
  }

  static Future<SessionApprovalAnswer> _refused(
    Future<SessionApprovalAnswer> Function() answer,
  ) async {
    try {
      return await answer();
    } on SessionPromptRefusal catch (refusal) {
      throw RemoteApiRefusal(
        refusal.notFound || refusal.noTerminal
            ? ErrorCode.notFound
            : ErrorCode.badRequest,
        refusal.message,
      );
    }
  }
}

/// The attention word a phone's list shows for [report]: a prompt waiting on
/// a person, a failure, or nothing.
String? remoteAttentionOf(AgentStatusReport? report) =>
    switch (report?.status) {
      AgentActivityStatus.awaitingApproval => kAttentionNeedsApproval,
      AgentActivityStatus.failed => 'failed',
      _ => null,
    };

/// A menu read off the screen, as the wire and the shared card carry it.
RemoteMenu remoteMenuOf(AgentScreenMenu menu) => RemoteMenu(
  menuId: menu.id,
  prompt: menu.prompt,
  options: menu.options,
  highlighted: menu.highlighted,
);

RemoteWaitKind remoteWaitOf(AgentWaitKind kind) => switch (kind) {
  AgentWaitKind.approval => RemoteWaitKind.approval,
  AgentWaitKind.input => RemoteWaitKind.input,
  AgentWaitKind.unrecorded => RemoteWaitKind.unrecorded,
  AgentWaitKind.question => RemoteWaitKind.question,
};

/// A question, shaped exactly as the phone receives it.
RemoteQuestion remoteQuestionOf(AgentQuestionSet set) => RemoteQuestion(
  toolUseId: set.toolUseId,
  questions: [
    for (final q in set.questions)
      RemoteQuestionItem(
        question: q.question,
        header: q.header,
        multiSelect: q.multiSelect,
        options: [
          for (final o in q.options)
            RemoteQuestionOption(label: o.label, description: o.description),
        ],
      ),
  ],
);
