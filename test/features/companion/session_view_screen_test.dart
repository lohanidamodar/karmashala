import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/fake_companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/session_view_screen.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
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
    // A prompt the host could actually see. Anything else and the keys below
    // would not be on the wire at all.
    waiting: RemoteWaitKind.approval,
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
            waiting: RemoteWaitKind.approval,
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

  // --- Stopped for you is not the same as asking you ------------------------
  //
  // Claude Code fires the same notification when it wants permission and when
  // it has merely finished its turn and is sitting at its own prompt. Approve
  // types Enter, and at that prompt Enter submits whatever is in the composer
  // — so a card that offers it there can send an unintended message to a live
  // agent. The desktop card branches on the wait kind; these are the phone's
  // half of the same rule.
  group('a session waiting for input, not approval', () {
    const waitingForInput = CompanionApproval(
      id: 'a3',
      sessionId: 's1',
      agentName: 'Claude Code',
      evidence: ['Claude is waiting for your input'],
      waiting: RemoteWaitKind.input,
    );

    testWidgets('is a notice with nothing to press', (tester) async {
      await pumpPhone(
        tester,
        gateway: gateway(approvals: const {'s1': waitingForInput}),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      expect(
        find.text('Claude Code is waiting for your input'),
        findsOneWidget,
      );
      // The agent's own words still travel; only the keys are withheld.
      expect(find.text('Claude is waiting for your input'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      // And it points at the answer that does exist: the composer below it.
      expect(find.textContaining('There is nothing to approve'), findsOneWidget);
    });

    testWidgets('refuses keys even if a host sends them anyway', (
      tester,
    ) async {
      // Belt and braces for an older desktop, which named approve and deny
      // for any session that had stopped for the user.
      await pumpPhone(
        tester,
        gateway: gateway(
          approvals: const {
            's1': CompanionApproval(
              id: 'a4',
              sessionId: 's1',
              agentName: 'Claude Code',
              waiting: RemoteWaitKind.input,
              approveLabel: 'Allow',
              denyLabel: 'Deny',
            ),
          },
        ),
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Deny'), findsNothing);
    });
  });

  testWidgets('a wait no source could name offers nothing to press', (
    tester,
  ) async {
    // `worker_permission_prompt`: a prompt drawn somewhere this session's
    // Enter does not land, so the host names no keys for it.
    await pumpPhone(
      tester,
      gateway: gateway(
        approvals: const {
          's1': CompanionApproval(
            id: 'a5',
            sessionId: 's1',
            agentName: 'Claude Code',
            evidence: ['a worker needs permission for Bash'],
          ),
        },
      ),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    expect(find.text('Claude Code needs your attention'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(
      find.textContaining('cannot tell whether Claude Code has a prompt open'),
      findsOneWidget,
    );
  });

  group('an approval answered elsewhere', () {
    // Seen on the phone, 2026-09-02: the card stayed live and actionable for a
    // decision the desktop had already made, because the protocol told the
    // phone when a request appeared and never when it went away.

    testWidgets('takes the card away and says why', (tester) async {
      final fake = gateway(approvals: const {'s1': approval});
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();
      expect(find.text('Claude Code is waiting for you'), findsOneWidget);

      fake.resolveApproval('s1');
      await tester.pump();
      await tester.pump();

      expect(find.text('Claude Code is waiting for you'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
      // Not a silent disappearance: a card that just vanishes reads as a
      // request that was dropped.
      expect(
        find.text('That request was already answered on the desktop.'),
        findsOneWidget,
      );
    });

    testWidgets("and this phone's own answer says which way it went", (
      tester,
    ) async {
      final fake = gateway(approvals: const {'s1': approval});
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Deny'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Declined.'), findsOneWidget);
    });

    testWidgets('a screen that was never shown one stays quiet', (
      tester,
    ) async {
      final fake = gateway();
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      fake.resolveApproval('s1');
      await tester.pump();
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('at a 200% text scale the card still goes', (tester) async {
      final fake = gateway(approvals: const {'s1': approval});
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
        textScale: 2.0,
      );
      await tester.pump();
      // It used to overflow the footer by 34px here. The card is now capped
      // against the viewport and scrolls inside that cap, so the reader who
      // needs the largest text still gets a laid-out card.
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(FilledButton, 'Allow'), findsOneWidget);

      fake.resolveApproval('s1');
      await tester.pump();
      await tester.pump();

      expect(find.text('Claude Code is waiting for you'), findsNothing);
      expect(
        find.text('That request was already answered on the desktop.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
