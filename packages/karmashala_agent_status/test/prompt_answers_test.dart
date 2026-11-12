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

final _idle = AgentStatusReport(
  agentId: 'claudeCode',
  sessionId: 'conv',
  status: AgentActivityStatus.idle,
  source: AgentStatusSource.terminalGrid,
  observedAt: DateTime.utc(2026, 11, 12),
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

  test('an agent\'s approve into an idle session with no menu presses '
      'nothing and files nothing', () async {
    final terminals = _Terminals(
      claude,
      FixtureMenuScreen.text('', marker: '❯'),
    )..status = _idle;

    for (final approve in [true, false]) {
      await expectLater(
        answersOver(terminals).answer(
          ApprovalAnswerRequest(
            sessionId: 's1',
            approve: approve,
            requireOpenPrompt: false,
          ),
        ),
        throwsA(
          isA<SessionPromptRefusal>().having(
            (r) => r.message,
            'message',
            contains('no prompt is open in that session'),
          ),
        ),
      );
    }
    expect(terminals.screenOf!.sent, isEmpty);
    expect(terminals.recorded, isEmpty);
  });

  test('a menu drawn before the status caught up is chosen from', () async {
    final terminals = _Terminals(
      claude,
      FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
    )..status = _idle;
    final answers = answersOver(terminals);
    final menu = answers.drawnMenu('s1')!;
    expect(answers.menuOnScreen('s1'), isNull);

    final answer = await answers.answer(
      MenuAnswerRequest(sessionId: 's1', menuId: menu.id, option: 1),
    );

    expect(answer.answered, 'Yes, I trust this folder');
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

  group('an approval drawn from a call', () {
    final since = DateTime.utc(2026, 11, 3, 3, 18, 54);
    AgentStatusReport askingAbout(String call) =>
        _asking(AgentWaitKind.approval).withAsk(
          toolAsk: AgentToolAsk(
            toolName: 'Bash',
            input: const {'command': 'ls'},
            at: since,
            toolUseId: call,
          ),
          waitingSince: since,
        );

    // A tall prompt is redrawn with other rows above its choices, and a
    // resize wraps them anew: the screen's id moves while the call's stays
    // (session f3976069, 2026-11-03).
    test('answers its prompt however the screen has redrawn it', () async {
      final terminals = _Terminals(
        claude,
        FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
      )..status = askingAbout('toolu_1');

      final answer = await answersOver(terminals).answer(
        ApprovalAnswerRequest(
          sessionId: 's1',
          approve: true,
          ask: PromptAsk(
            waitingSince: since,
            toolUseId: 'toolu_1',
            menuId: 'the-rows-it-was-drawn-with',
          ),
        ),
      );

      expect(answer.answered, 'Yes, I trust this folder');
    });

    test('is refused once the status names another call', () async {
      final terminals = _Terminals(
        claude,
        FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
      )..status = askingAbout('toolu_2');

      await expectLater(
        answersOver(terminals).answer(
          ApprovalAnswerRequest(
            sessionId: 's1',
            approve: true,
            ask: PromptAsk(waitingSince: since, toolUseId: 'toolu_1'),
          ),
        ),
        throwsA(
          isA<SessionPromptRefusal>().having((r) => r.stale, 'stale', true),
        ),
      );
      expect(terminals.screenOf!.sent, isEmpty);
    });

    test('with no call, a menu drawn otherwise is still refused', () async {
      final terminals = _Terminals(
        claude,
        FixtureMenuScreen.fixture('claude-code-trust-prompt', marker: '❯'),
      )..status = _asking(AgentWaitKind.approval);

      await expectLater(
        answersOver(terminals).answer(
          const ApprovalAnswerRequest(
            sessionId: 's1',
            approve: true,
            ask: PromptAsk(menuId: 'the-rows-it-was-drawn-with'),
          ),
        ),
        throwsA(
          isA<SessionPromptRefusal>().having((r) => r.stale, 'stale', true),
        ),
      );
      expect(terminals.screenOf!.sent, isEmpty);
    });
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
          contains('the question changed since it was shown'),
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
