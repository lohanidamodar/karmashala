/// "I opened a session active here, but it keeps loading."
///
/// The invariant these pin: **no companion screen may load forever**. Every
/// path through the session view ends in content, an empty state, or a
/// readable error with a way forward — including a session that keeps no
/// transcript, a host that refuses, and a desktop that never answers.
library;

import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/fake_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/presentation/session_view_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  FakeCompanionGateway paired({
    Map<String, List<CompanionChatMessage>> transcripts = const {},
    CompanionLinkState link = CompanionLinkState.connected,
  }) => FakeCompanionGateway.paired(
    sessions: [summary('s1', title: 'Fix the login flow')],
    transcripts: transcripts,
    link: link,
  );

  testWidgets('a host that refuses the transcript says so, with a way to try '
      'again — it does not sit on a spinner', (tester) async {
    final gateway = paired();
    gateway.transcriptFailures['s1'] = const GatewayException(
      'This phone was not granted transcript rights.',
    );

    await pumpPhone(
      tester,
      gateway: gateway,
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();
    // Long enough for a provider retry to come round, which is exactly when
    // the old code went back to a skeleton and stayed there.
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.text('This phone was not granted transcript rights.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a session with no transcript gets an honest empty state, not a '
      'promise that one is coming', (tester) async {
    await pumpPhone(
      tester,
      gateway: paired(transcripts: const {'s1': []}),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    // Some agents keep no transcript at all; the phone cannot tell that from
    // "nothing said yet", so it must not claim either.
    expect(find.textContaining('No transcript'), findsOneWidget);
    expect(find.textContaining('keep none'), findsOneWidget);
  });

  testWidgets('a transcript that never answers while the desktop is '
      'unreachable stops pretending it is loading', (tester) async {
    final gateway = paired(link: CompanionLinkState.disconnected);
    gateway.stalledTranscripts.add('s1');

    await pumpPhone(
      tester,
      gateway: gateway,
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('desktop'), findsWidgets);
  });

  testWidgets('a transcript still on its way over a live link may show a '
      'skeleton — that one IS honest', (tester) async {
    final gateway = paired();
    gateway.stalledTranscripts.add('s1');

    await pumpPhone(
      tester,
      gateway: gateway,
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
