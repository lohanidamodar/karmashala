import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/events.dart';
import 'package:test/test.dart';

import 'fixture_menu_screen.dart';

/// A terminal holder over one captured screen: what the session host is to a
/// session it runs, and the app to a pane of its own.
class _Terminals implements PromptTerminals {
  _Terminals(this.agent, this.screenOf);

  final AgentDescriptor agent;
  final FixtureMenuScreen? screenOf;
  AgentStatusReport? status;
  AgentQuestionSet? question;
  final recorded = <DecisionRecord>[];

  @override
  bool exists(String sessionId) => sessionId == 's1';

  @override
  AgentDescriptor? agentOf(String sessionId) => agent;

  @override
  AgentStatusReport? statusOf(String sessionId) => status;

  @override
  Future<AgentQuestionSet?> openQuestion(String sessionId) async => question;

  @override
  List<String>? screen(String sessionId) => screenOf?.rows();

  @override
  bool press(String sessionId, String keys) => screenOf?.press(keys) ?? false;

  @override
  void record(DecisionRecord decision) => recorded.add(decision);
}

AgentStatusReport _asking(AgentWaitKind waiting) => AgentStatusReport(
  agentId: 'claudeCode',
  sessionId: 'conv',
  status: AgentActivityStatus.awaitingApproval,
  source: AgentStatusSource.terminalGrid,
  observedAt: DateTime.utc(2026, 9, 25),
  waiting: waiting,
);

void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;

  SessionPromptAnswers answersOver(_Terminals terminals) =>
      SessionPromptAnswers(
        terminals: terminals,
        menuPoll: const Duration(milliseconds: 1),
        menuPatience: const Duration(milliseconds: 300),
      );

  test(
    'approve on folder trust chooses the trusting option, and files it',
    () async {
      final terminals = _Terminals(
        claude,
        FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
      )..status = _asking(AgentWaitKind.approval);

      final answer = await answersOver(
        terminals,
      ).answer(const ApprovalAnswerRequest(sessionId: 's1', approve: true));

      expect(answer.answered, 'Yes, I trust this folder');
      expect(terminals.screenOf!.confirmed, 'Yes, I trust this folder');
      expect(terminals.recorded.single.kind, DecisionKind.approvalGranted);
      expect(terminals.recorded.single.origin, DecisionOrigin.approvalPrompt);
    },
  );

  test('refused with nothing pressed while no prompt is open', () async {
    final terminals = _Terminals(
      claude,
      FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
    )..status = _asking(AgentWaitKind.input);

    await expectLater(
      answersOver(
        terminals,
      ).answer(const ApprovalAnswerRequest(sessionId: 's1', approve: true)),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(terminals.screenOf!.sent, isEmpty);
  });

  test('an unknown session is refused as not found', () async {
    final terminals = _Terminals(claude, null);
    await expectLater(
      answersOver(
        terminals,
      ).answer(const ApprovalAnswerRequest(sessionId: 'nope', approve: true)),
      throwsA(
        isA<SessionPromptRefusal>().having((r) => r.notFound, 'notFound', true),
      ),
    );
  });

  test('evidence offers the menu, never approve/deny beside it', () async {
    final terminals = _Terminals(
      claude,
      FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
    )..status = _asking(AgentWaitKind.approval);

    final evidence = await answersOver(terminals).evidence('s1');

    expect(evidence.menu!.options, contains('Yes, I trust this folder'));
    expect(evidence.approve, isNull);
    expect(evidence.deny, isNull);
  });

  test('a question answer naming another call is refused', () async {
    final terminals = _Terminals(claude, null)
      ..status = _asking(AgentWaitKind.question)
      ..question = const AgentQuestionSet(
        toolUseId: 'toolu_now',
        questions: [
          AgentQuestion(
            question: 'Pick',
            options: [AgentQuestionOption(label: 'A')],
          ),
        ],
      );

    await expectLater(
      answersOver(terminals).answer(
        const QuestionAnswerRequest(
          sessionId: 's1',
          toolUseId: 'toolu_before',
          answers: [AgentQuestionAnswer.option(0)],
        ),
      ),
      throwsA(
        isA<SessionPromptRefusal>().having(
          (r) => r.message,
          'message',
          contains('already been answered'),
        ),
      ),
    );
  });

  test('requests survive the wire', () {
    const requests = <PromptAnswerRequest>[
      ApprovalAnswerRequest(
        sessionId: 's1',
        approve: false,
        requireOpenPrompt: false,
        decidedBy: 'an agent in session s2',
        decidedBySessionId: 's2',
      ),
      MenuAnswerRequest(sessionId: 's1', menuId: 'm', option: 2),
      QuestionAnswerRequest(
        sessionId: 's1',
        toolUseId: 't',
        answers: [
          AgentQuestionAnswer.options([0, 2]),
          AgentQuestionAnswer.text('own words'),
        ],
      ),
    ];
    for (final request in requests) {
      final back = PromptAnswerRequest.fromJson(request.toJson())!;
      expect(back.toJson(), request.toJson());
    }
  });
}
