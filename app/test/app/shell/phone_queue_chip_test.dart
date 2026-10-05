import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import 'package:karmashala/src/features/sessions/application/session_queue_providers.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The phone's session bar carries the queue**: a phone has no other way into
/// the messages waiting for a session, in the chat or on the terminal, so the
/// "N queued" chip stays in its one row and opens the queue (owner,
/// 2026-10-05: three messages waited unseen behind a phone's bar).
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  QueuedMessage queued(String id, int seq) => QueuedMessage(
    id: id,
    sessionId: 'acp-1',
    seq: seq,
    text: 'message $seq',
    state: QueuedMessageState.queued,
    origin: QueuedMessageOrigin.device,
    createdAt: testTime,
    updatedAt: testTime,
  );

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => const SessionDelivery(
            branch: 'session/fix-the-login-form-validation',
            baseBranch: 'origin/main',
            hasRemote: true,
            dirtyFiles: 2,
            aheadOfBase: 3,
            hasWorktree: true,
          ),
        ),
        sessionContinuationProvider.overrideWith(
          (ref, _) => SessionContinuation(
            targets: const [],
            plan: SessionForkPlan.decide(descriptor: null, agentName: 'ACP'),
          ),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.working,
              observedAt: testTime,
              source: AgentStatusSource.none,
            ),
          ),
        ),
        sessionQueueProvider.overrideWith(
          (ref, _) => [queued('q1', 1), queued('q2', 2), queued('q3', 3)],
        ),
      ],
    );
    addTearDown(container.dispose);
    db.server.sessionRows.insert(
      Session(
        id: 'acp-1',
        repositoryId: 'r1',
        agentInstallationId: 'acp',
        title: 'Over ACP',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: CompactWorkbenchScope(child: WorkbenchView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the phone bar shows the queued count, and a tap opens the '
      'queue', (tester) async {
    await pump(tester);

    final chip = find.byKey(const ValueKey('queued-count'));
    expect(chip, findsOneWidget);
    expect(find.text('3 queued'), findsOneWidget);

    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.text('Queued messages'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
