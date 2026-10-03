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
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **An ACP session whose start was refused is sent to like any other** —
/// failed, no conversation named, nothing in its transcript. The composer
/// offers to continue it, a message starts a fresh conversation in the same
/// row at the server, and a refusal of that start reaches the composer in
/// the server's words.
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

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip(RegExp('^Send')));
    await tester.pumpAndSettle();
  }

  testWidgets('the composer offers to continue it, not to message an agent '
      'that is not running', (tester) async {
    await pump(tester);

    expect(find.text('Type to continue this session…'), findsOneWidget);
    expect(find.text('Message the agent…'), findsNothing);
  });

  testWidgets('a message starts it again at the server and is its first '
      'turn', (tester) async {
    await pump(tester);

    await send(tester, 'try again');

    expect(server.sessionWork.sent.map((s) => s.text), ['try again']);
    expect(server.sessionWork.running, {'acp-1'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a start refused again is said in the server\'s words, and '
      'the draft is kept', (tester) async {
    server.sessionWork.resumeOnSendRefusesWith =
        'This session is not running and could not be resumed to take the '
        'message, so nothing was sent: GitHub Copilot asks to be logged in '
        'first.';
    await pump(tester);

    await send(tester, 'try again');

    expect(server.sessionWork.sent, isEmpty);
    expect(find.text('try again'), findsOneWidget);
    // A snackbar is gone in seconds; the composer keeps the words.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('composer-send-error')),
        matching: find.textContaining('asks to be logged in first'),
        matchRoot: true,
      ),
      findsOneWidget,
    );

    // The next attempt clears it, and lands.
    server.sessionWork.resumeOnSendRefusesWith = null;
    await tester.tap(find.byTooltip(RegExp('^Send')));
    await tester.pumpAndSettle();
    expect(server.sessionWork.sent.map((s) => s.text), ['try again']);
    expect(find.byKey(const ValueKey('composer-send-error')), findsNothing);
  });
}
