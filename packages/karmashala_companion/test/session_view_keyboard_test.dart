import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

/// The session view with the keyboard up: the composer is the one thing the
/// user is typing into, so it must stay on screen whatever sits above it.
void main() {
  const approval = CompanionApproval(
    id: 'a1',
    sessionId: 's1',
    agentName: 'Claude Code',
    evidence: ['Bash(rm -rf build/)', 'Do you want to proceed?', '1. Yes', '2. No'],
    waiting: RemoteWaitKind.approval,
    approveLabel: 'Allow',
    denyLabel: 'Deny',
  );

  FakeCompanionGateway gateway() {
    final fake = FakeCompanionGateway.paired(
      sessions: [summary('s1', whereabouts: 'open in another process')],
      transcripts: {
        's1': const [CompanionChatMessage(role: 'agent', text: 'hi')],
      },
      approvals: const {'s1': approval},
    );
    fake.setActivity(
      's1',
      CompanionActivity(
        at: DateTime.now(),
        calls: const [
          CompanionActivityCall(
            summary: 'Bash(flutter test)',
            elapsed: Duration(seconds: 12),
          ),
        ],
      ),
    );
    return fake;
  }

  for (final (size, scale, keyboard) in const [
    (Size(360, 800), 1.0, 300.0),
    (Size(360, 800), 1.3, 300.0),
    (Size(360, 800), 2.0, 300.0),
    (Size(320, 640), 1.0, 300.0),
    (Size(320, 640), 2.0, 300.0),
    (Size(800, 360), 1.0, 180.0),
    (Size(800, 360), 2.0, 180.0),
    (Size(320, 640), 2.0, 0.0),
    (Size(800, 360), 2.0, 0.0),
  ]) {
    testWidgets(
      'composer stays visible at ${size.width.toInt()}x${size.height.toInt()} '
      '@$scale with a ${keyboard.toInt()}px keyboard and an approval pending',
      (tester) async {
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        addTearDown(tester.view.resetViewInsets);
        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        try {
          await pumpPhone(
            tester,
            size: size,
            textScale: scale,
            gateway: gateway(),
            home: const SessionViewScreen(sessionId: 's1'),
          );
          await tester.pump();
        } finally {
          FlutterError.onError = previous;
        }

        expect(
          errors.map((e) => '${e.exception}'),
          isNot(contains(contains('overflowed'))),
        );
        final field = find.byType(TextField);
        expect(field, findsOneWidget);
        final rect = tester.getRect(field);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height - keyboard));
        expect(rect.height, greaterThan(0));
        // The approval is still reachable, not pushed off the bottom.
        expect(find.text('Allow', skipOffstage: false), findsOneWidget);
      },
    );
  }
}
