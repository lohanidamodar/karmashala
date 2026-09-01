import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/session_view_screen.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

/// The session view on the phone: the desktop transcript, a composer reduced
/// to sending a prompt, and the approval card with its verbatim evidence.
void main() {
  const approval = CompanionApproval(
    id: 'a1',
    sessionId: 's1',
    agentName: 'Claude Code',
    evidence: ['Bash(rm -rf build/)', 'Do you want to proceed?'],
    approveLabel: 'Allow',
    approveEffect: 'presses Enter in its terminal',
    denyLabel: 'Deny',
    denyEffect: 'presses Esc in its terminal',
  );

  FakeCompanionGateway gateway({
    Map<String, CompanionApproval> approvals = const {},
  }) => FakeCompanionGateway.paired(
    sessions: [
      summary(
        's1',
        title: 'Fix the login flow',
        whereabouts: 'open in another process',
      ),
    ],
    transcripts: {
      's1': const [
        CompanionChatMessage(role: 'user', text: 'hello'),
        CompanionChatMessage(role: 'agent', text: 'hi'),
      ],
    },
    approvals: approvals,
  );

  testWidgets('renders the transcript with the desktop chat shapes', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: gateway(),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.text('Fix the login flow'), findsOneWidget);
    // The desktop tile gutters: You / Agent, uppercased.
    expect(find.text('YOU'), findsOneWidget);
    expect(find.text('AGENT'), findsOneWidget);
    expect(find.text('hello', findRichText: true), findsOneWidget);
    expect(find.text('hi', findRichText: true), findsOneWidget);
  });

  testWidgets('sending a prompt goes through the gateway', (tester) async {
    final fake = gateway();
    await pumpPhone(
      tester,
      gateway: fake,
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'ship it');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    expect(fake.sentPrompts, [(sessionId: 's1', text: 'ship it')]);
    // The user turn lands in the transcript the phone is showing.
    expect(find.text('ship it', findRichText: true), findsOneWidget);
  });

  testWidgets('the approval card quotes the evidence verbatim', (tester) async {
    await pumpPhone(
      tester,
      gateway: gateway(approvals: const {'s1': approval}),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.text('Claude Code is waiting for you'), findsOneWidget);
    // Exactly the agent's rows, joined — never a paraphrase.
    expect(
      find.text('Bash(rm -rf build/)\nDo you want to proceed?'),
      findsOneWidget,
    );
    // Every button says which key it presses on the user's behalf.
    expect(find.text('Allow: presses Enter in its terminal'), findsOneWidget);
    expect(find.text('Deny: presses Esc in its terminal'), findsOneWidget);
  });

  testWidgets('answering an approval goes through the gateway and clears', (
    tester,
  ) async {
    final fake = gateway(approvals: const {'s1': approval});
    await pumpPhone(
      tester,
      gateway: fake,
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pump();
    await tester.pump();

    expect(fake.answeredApprovals.single.sessionId, 's1');
    expect(fake.answeredApprovals.single.approvalId, 'a1');
    expect(
      fake.answeredApprovals.single.decision,
      CompanionApprovalDecision.approve,
    );
    expect(find.text('Claude Code is waiting for you'), findsNothing);
  });

  testWidgets('an approval with no named deny explains itself', (tester) async {
    await pumpPhone(
      tester,
      gateway: gateway(
        approvals: const {
          's1': CompanionApproval(
            id: 'a2',
            sessionId: 's1',
            agentName: 'Codex',
            evidence: ['apply patch?'],
            approveLabel: 'Approve',
            approveEffect: 'presses y',
          ),
        },
      ),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.textContaining('names no way to decline'), findsOneWidget);
  });

  testWidgets('a phone without the approve capability cannot answer', (
    tester,
  ) async {
    final fake = FakeCompanionGateway.paired(
      sessions: [summary('s1')],
      approvals: const {'s1': approval},
      capabilities: CapabilitySet.of(const [
        Capability.viewSessions,
        Capability.readTranscript,
        Capability.sendPrompt,
      ]),
    );
    await pumpPhone(
      tester,
      gateway: fake,
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
    expect(find.textContaining('not granted approval rights'), findsOneWidget);
  });
}
