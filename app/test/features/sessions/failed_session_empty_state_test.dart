import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A session that ended in error says so** where its transcript would be:
/// the follow-up's own words and a way to start it again, never "Ready to
/// assist".
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
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
    server.sessionWork
      ..typesSends = true
      ..resumesOnSend = true;
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.failed,
      ),
    );
  });

  Future<void> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {
              'sessions.send',
              'sessions.interrupt',
              'sessions.send.resumes',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => false),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 'acp-1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('it names the error, not an empty conversation', (tester) async {
    server.followUpRows.raise(
      FollowUp(
        sessionId: 'acp-1',
        reason: FollowUpReason.endedInFailure,
        ending: SessionEnding.failed,
        raisedAt: testTime,
        summary: 'Copilot asks to be logged in first.',
      ),
    );
    await pump(tester);

    expect(find.text('Ready to assist'), findsNothing);
    expect(find.text('Ended in error'), findsOneWidget);
    expect(
      find.textContaining('Copilot asks to be logged in first.'),
      findsOneWidget,
    );
  });

  testWidgets('with nothing recorded it still says it failed', (tester) async {
    await pump(tester);

    expect(find.text('Ready to assist'), findsNothing);
    expect(find.text('Ended in error'), findsOneWidget);
  });

  testWidgets('Retry starts it again at the server', (tester) async {
    await pump(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(server.sessionRows.getById('acp-1')!.status, SessionStatus.running);
    expect(find.text('Ended in error'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
