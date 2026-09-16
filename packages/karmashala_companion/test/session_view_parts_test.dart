import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

/// The session view's pieces, on their own.
void main() {
  group('companionOffersResume', () {
    test('never before the list is known, nor for a missing session', () {
      expect(
        companionOffersResume(
          summary('s1', status: CompanionSessionStatus.idle),
          listKnown: false,
        ),
        isFalse,
      );
      expect(companionOffersResume(null, listKnown: true), isFalse);
    });

    test('for an idle, failed, unknown or imported session', () {
      for (final status in const [
        CompanionSessionStatus.idle,
        CompanionSessionStatus.failed,
        CompanionSessionStatus.unknown,
      ]) {
        expect(
          companionOffersResume(summary('s1', status: status), listKnown: true),
          isTrue,
          reason: '$status',
        );
      }
      expect(
        companionOffersResume(summary('s1', imported: true), listKnown: true),
        isTrue,
      );
    });

    test('not for a session that is working', () {
      expect(
        companionOffersResume(
          summary('s1', status: CompanionSessionStatus.working),
          listKnown: true,
        ),
        isFalse,
      );
    });
  });

  testWidgets('the status strip joins what it knows and badges the status', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const SessionStatusStrip(
        status: CompanionSessionStatus.idle,
        agentLabel: 'Claude Code',
        stageLabel: 'Merged',
      ),
    );

    expect(find.text('Claude Code  ·  Merged'), findsOneWidget);
    expect(find.byType(CompanionStatusBadge), findsOneWidget);
  });

  testWidgets('the status strip draws no badge before the status is known', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const SessionStatusStrip(),
    );
    expect(find.byType(CompanionStatusBadge), findsNothing);
  });

  testWidgets('the footer puts the approval above the activity and resume', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(sessions: [summary('s1')]),
      home: SessionFooter(
        sessionId: 's1',
        approval: const CompanionApproval(
          id: 'a1',
          sessionId: 's1',
          agentName: 'Claude Code',
          evidence: ['Do you want to proceed?'],
          waiting: RemoteWaitKind.approval,
          approveLabel: 'Allow',
          denyLabel: 'Deny',
        ),
        canApprove: true,
        onAnswer: (_) async {},
        resume: const Text('resume-here'),
      ),
    );

    expect(find.byType(CompanionApprovalCard), findsOneWidget);
    expect(find.byType(CompanionActivityStrip), findsOneWidget);
    expect(
      tester.getRect(find.byType(CompanionApprovalCard)).bottom,
      lessThanOrEqualTo(tester.getRect(find.text('resume-here')).top),
    );
  });

  testWidgets('the footer leaves out what it is not given', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(sessions: [summary('s1')]),
      home: SessionFooter(
        sessionId: 's1',
        showActivity: false,
        onAnswer: (_) async {},
      ),
    );

    expect(find.byType(CompanionApprovalCard), findsNothing);
    expect(find.byType(CompanionActivityStrip), findsNothing);
  });
}
