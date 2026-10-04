import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

/// **An ACP agent's own options on the phone's approval card**: each one the
/// agent offered, in its words and order, answering with exactly that option.
void main() {
  const options = [
    RemoteApprovalOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
    RemoteApprovalOption(
      id: 'allow-always',
      name: 'Always allow',
      kind: 'allow_always',
    ),
    RemoteApprovalOption(id: 'reject', name: 'Reject', kind: 'reject_once'),
    RemoteApprovalOption(
      id: 'reject-always',
      name: 'Never allow',
      kind: 'reject_always',
    ),
  ];

  const approval = CompanionApproval(
    id: 'a1',
    sessionId: 's1',
    agentName: 'Claude Agent',
    evidence: ['Run tests'],
    waiting: RemoteWaitKind.approval,
    approveLabel: 'Allow',
    denyLabel: 'Reject',
    options: options,
  );

  FakeCompanionGateway gateway() => FakeCompanionGateway.paired(
    sessions: [summary('s1', title: 'Fix the login flow')],
    transcripts: const {'s1': []},
    approvals: const {'s1': approval},
  );

  testWidgets('every option is a button, in the agent\'s order', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: gateway(),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pump();

    final xs = <double>[];
    final ys = <double>[];
    for (final option in options) {
      final button = find.byKey(ValueKey('approval-option-${option.id}'));
      expect(button, findsOneWidget, reason: option.name);
      expect(
        find.descendant(of: button, matching: find.text(option.name)),
        findsOneWidget,
      );
      xs.add(tester.getTopLeft(button).dx);
      ys.add(tester.getTopLeft(button).dy);
    }
    final order = [
      for (var i = 0; i < options.length; i++) (ys[i], xs[i]),
    ];
    final sorted = [...order]
      ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    expect(order, sorted);
    expect(tester.takeException(), isNull);
  });

  for (final option in options) {
    testWidgets('"${option.name}" answers with that option', (tester) async {
      final fake = gateway();
      await pumpPhone(
        tester,
        gateway: fake,
        home: const SessionViewScreen(sessionId: 's1'),
      );
      await tester.pump();

      await tester.ensureVisible(
        find.byKey(ValueKey('approval-option-${option.id}')),
      );
      await tester.tap(find.byKey(ValueKey('approval-option-${option.id}')));
      await tester.pump();
      await tester.pump();

      expect(fake.answeredApprovalOptions, [option.id]);
      expect(
        fake.answeredApprovals.single.decision,
        option.allows
            ? CompanionApprovalDecision.approve
            : CompanionApprovalDecision.deny,
      );
    });
  }
}
