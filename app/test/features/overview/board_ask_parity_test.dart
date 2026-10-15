import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The board answers an ask as the dock does**: every option the agent
/// offered, in its words and order, and its keys only where they are honest.
void main() {
  const consent = [
    AgentToolAskOption(id: 'accept', name: 'Allow', kind: 'allow_always'),
    AgentToolAskOption(id: 'decline', name: 'Decline', kind: 'reject_once'),
    AgentToolAskOption(id: 'cancel', name: 'Cancel', kind: 'reject_once'),
  ];
  const exitPlan = [
    AgentToolAskOption(
      id: 'auto',
      name: 'Yes, and use auto mode',
      kind: 'allow_always',
    ),
    AgentToolAskOption(
      id: 'acceptEdits',
      name: 'Yes, and accept edits',
      kind: 'allow_always',
    ),
    AgentToolAskOption(
      id: 'default',
      name: 'Yes, and ask before edits',
      kind: 'allow_once',
    ),
    AgentToolAskOption(
      id: 'plan',
      name: 'No, keep planning',
      kind: 'reject_once',
    ),
  ];
  const choices = [
    AgentToolAskOption(id: 'choice-0', name: 'feat/acp', kind: 'allow_always'),
    AgentToolAskOption(id: 'choice-1', name: 'main', kind: 'allow_always'),
    AgentToolAskOption(
      id: 'choice-2',
      name: 'a new branch',
      kind: 'allow_always',
    ),
    AgentToolAskOption(
      id: 'skip',
      name: 'Skip the question',
      kind: 'reject_once',
    ),
  ];

  AgentStatusReport asking(
    List<AgentToolAskOption> options, {
    String? reason,
    String? asker,
  }) => AgentStatusReport(
    agentId: AgentIds.claudeAcp,
    sessionId: 's1',
    status: AgentActivityStatus.awaitingApproval,
    source: AgentStatusSource.protocol,
    observedAt: testTime,
    waiting: AgentWaitKind.approval,
    waitingSince: testTime,
    toolAsk: AgentToolAsk(
      toolName: 'Run tests',
      input: const {'command': 'dart test'},
      at: testTime,
      toolUseId: 'c1',
      options: options,
      kind: 'execute',
      reason: reason,
      asker: asker,
    ),
  );

  Future<(ProviderContainer, _Recorder)> pump(
    WidgetTester tester,
    AgentStatusReport report, {
    Size? size,
    double textScale = 1,
    AgentScreenMenu? menu,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(agentId: report.agentId));
    db.server.sessionRows.insert(session(agentInstallationId: 'a1'));
    final recorder = _Recorder(menu: menu);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(report),
        ),
        sessionStatusLookupProvider.overrideWithValue((_) => report),
        sessionAnswerableProvider.overrideWithValue((_) => true),
        sessionPromptAnswersProvider.overrideWithValue(recorder),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ApprovalRequestCard(
                sessionId: 's1',
                board: true,
                where: 'Windows · branch feat/acp',
                onEdit: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, recorder);
  }

  /// The labels of [options]' buttons, in reading order.
  List<String> drawn(WidgetTester tester, List<AgentToolAskOption> options) {
    Offset at(AgentToolAskOption o) => tester.getTopLeft(find.text(o.name));
    final read = [...options]
      ..sort((a, b) {
        final dy = at(a).dy.compareTo(at(b).dy);
        return dy != 0 ? dy : at(a).dx.compareTo(at(b).dx);
      });
    return [for (final o in read) o.name];
  }

  Future<String?> key(ProviderContainer c, BoardApproval kind) =>
      answerBoardApprovalBy(c.read, 's1', kind);

  group('the agent\'s options, in its words and order', () {
    testWidgets('MCP consent: Allow, Decline, Cancel; Allow sends accept', (
      tester,
    ) async {
      final (_, recorder) = await pump(tester, asking(consent));
      for (final o in consent) {
        expect(find.text(o.name), findsOneWidget, reason: o.name);
      }
      expect(drawn(tester, consent), ['Allow', 'Decline', 'Cancel']);
      expect(find.text('Always'), findsNothing);

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      final sent = recorder.asked.single as ApprovalAnswerRequest;
      expect((sent.optionId, sent.approve), ('accept', true));
    });

    testWidgets('ExitPlanMode: all four, each sending its own option', (
      tester,
    ) async {
      final (_, recorder) = await pump(tester, asking(exitPlan));
      expect(drawn(tester, exitPlan), [for (final o in exitPlan) o.name]);
      for (final o in exitPlan) {
        await tester.tap(find.text(o.name));
        await tester.pumpAndSettle();
        final sent = recorder.asked.last as ApprovalAnswerRequest;
        expect(sent.optionId, o.id);
        expect(sent.approve, o.allows);
        expect(sent.ask?.toolUseId, 'c1');
      }
      expect(recorder.asked, hasLength(4));
    });

    testWidgets('a choice list: every choice is shown', (tester) async {
      await pump(tester, asking(choices));
      expect(drawn(tester, choices), [for (final o in choices) o.name]);
    });

    testWidgets('a key cap only on the button its key sends', (tester) async {
      await pump(tester, asking(consent));
      // Y is the sole allowing option; there is no real "always"; D the
      // first decline.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('board-allow:s1')),
          matching: find.text('Y'),
        ),
        findsOneWidget,
      );
      expect(find.text('A'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('board-deny:s1')),
          matching: find.text('D'),
        ),
        findsOneWidget,
      );
      expect(find.text('Y'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
    });

    testWidgets('why it asks, and who, on one line', (tester) async {
      await pump(
        tester,
        asking(
          consent,
          reason: 'Path is outside the allowed working directories',
          asker: 'Explore',
        ),
      );
      final line = tester.widget<Text>(
        find.byKey(const ValueKey('board-ask-reason:s1')),
      );
      expect(
        line.data,
        'Asked by Explore · Path is outside the allowed working directories',
      );
      expect(line.maxLines, 1);
      // The board's own parts stay.
      expect(find.byKey(const ValueKey('board-where:s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('board-edit:s1')), findsOneWidget);
    });

    testWidgets('360 px at text scale 1.6, four long options: no overflow', (
      tester,
    ) async {
      const long = [
        AgentToolAskOption(
          id: 'a',
          name: 'Yes, and use auto mode for the rest of this session',
          kind: 'allow_always',
        ),
        AgentToolAskOption(
          id: 'b',
          name: 'Yes, and accept every edit without asking me again',
          kind: 'allow_always',
        ),
        AgentToolAskOption(
          id: 'c',
          name: 'Yes, but ask me before each edit it makes to a file',
          kind: 'allow_once',
        ),
        AgentToolAskOption(
          id: 'd',
          name: 'No, keep planning and tell me what you would change',
          kind: 'reject_once',
        ),
      ];
      await pump(
        tester,
        asking(long),
        size: const Size(360, 800),
        textScale: 1.6,
      );
      expect(tester.takeException(), isNull);
      for (final o in long) {
        expect(find.text(o.name), findsOneWidget);
      }
    });
  });

  group('Y / A / D', () {
    testWidgets('MCP consent: Y allows, no Always, D declines', (tester) async {
      final (c, recorder) = await pump(tester, asking(consent));
      expect(boardApprovalOffersBy(c.read, 's1'), {
        BoardApproval.allow,
        BoardApproval.deny,
      });
      expect(await key(c, BoardApproval.allow), isNull);
      expect((recorder.asked.last as ApprovalAnswerRequest).optionId, 'accept');
      expect(
        await key(c, BoardApproval.always),
        'This prompt offers no way to always allow.',
      );
      expect(await key(c, BoardApproval.deny), isNull);
      expect(
        (recorder.asked.last as ApprovalAnswerRequest).optionId,
        'decline',
      );
      expect(recorder.asked, hasLength(2));
    });

    testWidgets('ExitPlanMode: Y once, A the first always, D the reject', (
      tester,
    ) async {
      final (c, recorder) = await pump(tester, asking(exitPlan));
      String? last() => (recorder.asked.last as ApprovalAnswerRequest).optionId;
      expect(await key(c, BoardApproval.allow), isNull);
      expect(last(), 'default');
      expect(await key(c, BoardApproval.always), isNull);
      expect(last(), 'auto');
      expect(await key(c, BoardApproval.deny), isNull);
      expect(last(), 'plan');
    });

    testWidgets('a choice list: neither Y nor A picks a choice', (
      tester,
    ) async {
      final (c, recorder) = await pump(tester, asking(choices));
      expect(
        await key(c, BoardApproval.allow),
        'This prompt names no way to allow.',
      );
      expect(
        await key(c, BoardApproval.always),
        'This prompt offers no way to always allow.',
      );
      expect(recorder.asked, isEmpty);
      expect(await key(c, BoardApproval.deny), isNull);
      expect((recorder.asked.single as ApprovalAnswerRequest).optionId, 'skip');
    });
  });

  group('an approval with no call named', () {
    AgentStatusReport keysOnly() => AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: 's1',
      status: AgentActivityStatus.awaitingApproval,
      source: AgentStatusSource.hook,
      observedAt: testTime,
      waiting: AgentWaitKind.approval,
      waitingSince: testTime,
      evidence: const ['Claude needs your permission to use Bash'],
    );

    testWidgets("the dock's answers, without its terminal key caps", (
      tester,
    ) async {
      final (_, recorder) = await pump(tester, keysOnly());
      expect(find.text('Claude needs your permission to use Bash'), findsOne);
      expect(find.textContaining('is waiting for you'), findsNothing);
      expect(find.text('Enter'), findsNothing);
      expect(find.text('Esc'), findsNothing);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect((recorder.asked.single as ApprovalAnswerRequest).approve, isTrue);
    });

    testWidgets("a menu on screen: each option is its own button", (
      tester,
    ) async {
      final (_, recorder) = await pump(
        tester,
        keysOnly(),
        menu: const AgentScreenMenu(
          prompt: ['New MCP servers found in this project'],
          options: ['Use this and all future MCP servers', 'Continue without'],
          highlighted: 0,
        ),
      );
      expect(find.byKey(const ValueKey('dock-menu-option-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('dock-menu-option-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dock-menu-option-1')));
      await tester.pumpAndSettle();
      expect((recorder.asked.single as MenuAnswerRequest).option, 1);
    });
  });
}

class _Recorder implements PromptAnswering {
  _Recorder({this.menu});

  final AgentScreenMenu? menu;
  final asked = <PromptAnswerRequest>[];

  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) async {
    asked.add(request);
    return const SessionApprovalAnswer(answered: 'ok', effect: 'ok');
  }

  @override
  Future<PromptEvidence> evidence(String sessionId) =>
      throw UnimplementedError();

  @override
  AgentScreenMenu? menuOnScreen(String sessionId) => menu;
}
