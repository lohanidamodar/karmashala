import 'dart:async';

import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_message_typist.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A message sent from a phone is never lost.** The owner's message to a
/// live terminal session, sent while the desktop restarted, vanished from the
/// composer and never reached the agent. A send the server did not take stays
/// in the box with the reason; it is never typed into this phone's own view
/// of the server's terminal instead.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late List<String> typedHere;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(id: 'pty'));
    server.sessionWork.typesSends = true;
    db.server.sessionRows.insert(
      session(
        id: 'pty-1',
        agentInstallationId: 'pty',
        status: SessionStatus.running,
      ).copyWith(externalSessionId: 'conv-1'),
    );
    typedHere = [];
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // A phone: the server is on another machine.
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: false,
            serverOs: 'windows',
            features: {'sessions.send', 'sessions.interrupt'},
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        // The phone's view of the session's terminal: it takes any keys,
        // and nothing can be read back off it.
        sessionMessageTypistProvider.overrideWithValue(
          SessionMessageTypist(
            readScreen: (_) => null,
            markersFor: (_) => null,
            type: (_, text) {
              typedHere.add(text);
              return true;
            },
            press: (_, _) => true,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 'pty-1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byTooltip(RegExp('^Send')));
    await tester.pump();
  }

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  testWidgets('the link drops while the message is on its way: it stays in '
      'the box, and nothing is typed here', (tester) async {
    server.sessionWork.running.add('pty-1');
    await pump(tester);
    final hold = server.hold = Completer<void>();

    await send(tester, 'hello from the phone');
    server.stop();
    hold.complete();
    await tester.pumpAndSettle();

    expect(composerText(tester), 'hello from the phone');
    expect(server.sessionWork.sent, isEmpty);
    expect(typedHere, isEmpty);

    // Back, so the client's redial ends before the test does.
    server.start();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('the server came back without the session yet: the message '
      'stays in the box with why, and is not typed into the view here', (
    tester,
  ) async {
    await pump(tester);

    await send(tester, 'hello from the phone');
    await tester.pumpAndSettle();

    expect(typedHere, isEmpty);
    expect(composerText(tester), 'hello from the phone');
    expect(find.textContaining('nothing was sent'), findsWidgets);
  });
}
