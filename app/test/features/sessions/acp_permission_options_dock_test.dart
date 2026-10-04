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

/// **An ACP agent's permission options in the dock**: every option it
/// offered, in its words and order, each answering with exactly that option.
void main() {
  const offered = [
    AgentToolAskOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
    AgentToolAskOption(
      id: 'allow-always',
      name: 'Always allow',
      kind: 'allow_always',
    ),
    AgentToolAskOption(id: 'reject', name: 'Reject', kind: 'reject_once'),
    AgentToolAskOption(
      id: 'reject-always',
      name: 'Never allow',
      kind: 'reject_always',
    ),
  ];

  final report = AgentStatusReport(
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
      options: offered,
      kind: 'execute',
    ),
  );

  Future<_Recorder> pump(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeAcp),
    );
    db.server.sessionRows.insert(session(agentInstallationId: 'a1'));
    final recorder = _Recorder();
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
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Spacer(),
                ApprovalRequestCard(sessionId: 's1', docked: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return recorder;
  }

  testWidgets('every option the agent offered, in its words and order', (
    tester,
  ) async {
    await pump(tester);
    for (final option in offered) {
      expect(
        find.byKey(ValueKey('dock-option-${option.id}')),
        findsOneWidget,
        reason: option.name,
      );
      expect(find.text(option.name), findsOneWidget);
    }
    // The board's own answers stand down for the agent's.
    expect(find.byKey(const ValueKey('dock-allow-once')), findsNothing);
    // In reading order: the row may wrap.
    Offset at(AgentToolAskOption o) =>
        tester.getTopLeft(find.byKey(ValueKey('dock-option-${o.id}')));
    final read = [...offered]
      ..sort((a, b) {
        final dy = at(a).dy.compareTo(at(b).dy);
        return dy != 0 ? dy : at(a).dx.compareTo(at(b).dx);
      });
    expect(read, offered);
  });

  for (final option in offered) {
    testWidgets('"${option.name}" answers with exactly that option', (
      tester,
    ) async {
      final recorder = await pump(tester);
      await tester.tap(find.byKey(ValueKey('dock-option-${option.id}')));
      await tester.pumpAndSettle();
      final sent = recorder.asked.single as ApprovalAnswerRequest;
      expect(sent.optionId, option.id);
      expect(sent.approve, option.allows);
      expect(sent.ask?.toolUseId, 'c1');
    });
  }

  testWidgets('a session with no terminal is not sent to one, and the call '
      'reads as what it does', (tester) async {
    await pump(tester);
    expect(find.text('Answer in the terminal'), findsNothing);
    expect(find.text('Terminal view'), findsNothing);
    expect(find.textContaining('wants to run a command'), findsOneWidget);
    expect(find.text('dart test'), findsOneWidget);
    expect(find.textContaining('{"command"'), findsNothing);
  });

  testWidgets('a phone draws them without overflowing', (tester) async {
    await pump(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.text('Never allow'), findsOneWidget);
  });
}

class _Recorder implements PromptAnswering {
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
  AgentScreenMenu? menuOnScreen(String sessionId) => null;
}
