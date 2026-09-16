import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/tokens.dart';

import 'companion_test_support.dart';

/// Small pieces of chrome at the edges of what a phone does: 320px at 200%
/// text, a notch in landscape.
void main() {
  List<String> overflows(List<FlutterErrorDetails> errors) => [
    for (final e in errors)
      if ('${e.exception}'.contains('overflowed')) '${e.exception}',
  ];

  testWidgets('the way back to all machines fits 320px at 2x', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await pumpPhone(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        gateway: FakeCompanionGateway.paired(
          sessions: [
            summary(
              's1',
              projectId: 'p1',
              environmentId: 'windows',
              environmentBadge: 'Windows',
              environmentKind: 'windowsNative',
            ),
            summary(
              's2',
              projectId: 'p2',
              project: 'droplet',
              environmentId: 'ssh:h1',
              environmentBadge: 'do-box',
              environmentKind: 'ssh',
            ),
          ],
        ),
        home: const SessionListScreen(),
      );
      await tester.tap(find.text('do-box'));
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previous;
    }

    expect(find.text('All machines'), findsOneWidget);
    expect(overflows(errors), isEmpty);
  });

  testWidgets('the project switcher in the app bar is a full touch target', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        sessions: [
          summary('s1', project: 'alpha', projectId: 'p1'),
          summary('s2', project: 'beta', projectId: 'p2'),
        ],
      ),
      home: const ProjectSessionsScreen(projectKey: 'p1'),
    );

    final target = find.ancestor(
      of: find.text('alpha'),
      matching: find.byType(InkWell),
    );
    expect(
      tester.getSize(target.first).height,
      greaterThanOrEqualTo(Touch.target),
    );
  });

  testWidgets('the diagnostics list keeps clear of a landscape notch', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(left: 48, right: 48);
    addTearDown(tester.view.resetPadding);
    await pumpPhone(
      tester,
      size: const Size(800, 360),
      gateway: FakeCompanionGateway.paired(),
      home: const CompanionLogScreen(),
    );

    final list = tester.getRect(find.byType(ListView));
    expect(list.left, greaterThanOrEqualTo(48));
    expect(list.right, lessThanOrEqualTo(800 - 48));
  });
}
