import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/host.dart' show RemoteApiRefusal;
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// A phone sees an ACP agent's own options on its approval card, and its
/// answer names the option it chose.
void main() {
  final at = DateTime.utc(2026, 10, 4);

  AgentStatusReport asking({List<AgentToolAskOption> options = const []}) =>
      AgentStatusReport(
        agentId: 'claude-acp',
        sessionId: 's1',
        status: AgentActivityStatus.awaitingApproval,
        source: AgentStatusSource.protocol,
        observedAt: at,
        waiting: AgentWaitKind.approval,
        evidence: const ['Run tests'],
        toolAsk: AgentToolAsk(
          toolName: 'Run tests',
          input: const {},
          at: at,
          toolUseId: 'c1',
          options: options,
        ),
      );

  test(
    "the card carries the agent's options, in its words and order",
    () async {
      final answers = _Answers(
        asking(
          options: const [
            AgentToolAskOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
            AgentToolAskOption(
              id: 'allow-always',
              name: 'Always allow',
              kind: 'allow_always',
            ),
            AgentToolAskOption(
              id: 'reject-always',
              name: 'Never',
              kind: 'reject_always',
            ),
          ],
        ),
      );
      final request = await CompanionPrompts(answers).approvalEvidence('s1');
      expect(request.options, const [
        RemoteApprovalOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
        RemoteApprovalOption(
          id: 'allow-always',
          name: 'Always allow',
          kind: 'allow_always',
        ),
        RemoteApprovalOption(
          id: 'reject-always',
          name: 'Never',
          kind: 'reject_always',
        ),
      ]);
    },
  );

  test('a prompt that is not an ACP ask carries none', () async {
    final request = await CompanionPrompts(
      _Answers(asking()),
    ).approvalEvidence('s1');
    expect(request.options, isEmpty);
  });

  test('an answer by option names it to the session', () async {
    final answers = _Answers(asking());
    final answered = await CompanionPrompts(
      answers,
    ).answerApprovalOption('s1', 'approve', 'allow-always');
    final request = answers.asked.single as ApprovalAnswerRequest;
    expect(request.optionId, 'allow-always');
    expect(request.approve, isTrue);
    expect(answered, 'Always allow');
  });

  test('a prompt already gone is refused to the phone in plain words: it '
      'was answered, and nothing was sent', () async {
    for (final refusal in const [
      SessionPromptRefusal('no menu is open in this session now', stale: true),
      SessionPromptRefusal(kPromptChangedRefusal, stale: true),
    ]) {
      final answers = _Answers(asking())..refusal = refusal;
      await expectLater(
        CompanionPrompts(answers).answerMenu(
          const RemoteMenuAnswerRequest(
            sessionId: 's1',
            menuId: 'a1b2c3d4',
            option: 1,
          ),
        ),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            'This prompt was already answered — nothing was sent.',
          ),
        ),
      );
    }
  });
}

class _Answers implements PromptAnswering {
  _Answers(this.report);

  final AgentStatusReport report;
  final asked = <PromptAnswerRequest>[];
  SessionPromptRefusal? refusal;

  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) async {
    asked.add(request);
    if (refusal case final refused?) throw refused;
    return const SessionApprovalAnswer(answered: 'Always allow', effect: '');
  }

  @override
  Future<PromptEvidence> evidence(String sessionId) async => PromptEvidence(
    report: report,
    approve: const AgentApprovalKey(keys: 'allow', label: 'Allow', effect: ''),
    deny: const AgentApprovalKey(keys: 'reject', label: 'Reject', effect: ''),
  );

  @override
  AgentScreenMenu? menuOnScreen(String sessionId) => null;
}
