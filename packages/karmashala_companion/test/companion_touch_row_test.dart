import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/src/application/companion_environments.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_ui/tokens.dart';

import 'companion_test_support.dart';

/// The one tappable row and the one divider every companion list draws.
void main() {
  List<String> overflows(List<FlutterErrorDetails> errors) => [
    for (final e in errors)
      if ('${e.exception}'.contains('overflowed')) '${e.exception}',
  ];

  testWidgets('a touch row is a full target and its trailing part gives way', (
    tester,
  ) async {
    var taps = 0;
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await pumpPhone(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        gateway: FakeCompanionGateway.paired(),
        home: Column(
          children: [
            CompanionTouchRow(
              onTap: () => taps++,
              leading: const Icon(Icons.circle),
              title: const Text('A title', maxLines: 1),
              trailing: const Text(
                'a trailing label far wider than the row',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }

    expect(overflows(errors), isEmpty);
    final row = tester.getSize(find.byType(CompanionTouchRow));
    expect(row.height, greaterThanOrEqualTo(Touch.target));
    expect(
      tester.getSize(find.text('a trailing label far wider than the row')).width,
      lessThanOrEqualTo(320 / 2),
    );
    await tester.tap(find.text('A title'));
    expect(taps, 1);
  });

  testWidgets('the machine index uses it, and fits 320px at 2x', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await pumpPhone(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        gateway: FakeCompanionGateway.paired(),
        home: EnvironmentIndex(
          environments: const [
            CompanionEnvironment(
              key: 'windows',
              label: 'Windows',
              kind: 'windowsNative',
              projects: 12,
              sessions: 3,
            ),
            CompanionEnvironment(
              key: 'ssh:h1',
              label: 'build-box.internal',
              kind: 'ssh',
              projects: 1,
              sessions: 1,
            ),
          ],
          onPick: (_) {},
        ),
      );
    } finally {
      FlutterError.onError = previous;
    }

    expect(find.byType(CompanionTouchRow), findsNWidgets(2));
    expect(find.byType(CompanionRowDivider), findsOneWidget);
    expect(overflows(errors), isEmpty);
  });

  testWidgets('the inbox rows are touch rows between shared dividers', (
    tester,
  ) async {
    CompanionSessionSummary needing(String id) => summary(
      id,
      attention: CompanionAttention(
        kind: CompanionAttentionKind.needsYou,
        at: DateTime.now().toUtc(),
      ),
    );
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        sessions: [needing('s1'), needing('s2')],
      ),
      home: const InboxScreen(),
    );

    expect(find.byType(CompanionTouchRow), findsNWidgets(2));
    expect(find.byType(CompanionRowDivider), findsOneWidget);
  });

  testWidgets('the desktop strip and the saved desktops use it too', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: const Column(
        children: [HostSwitcherBar(), ConnectionsSection()],
      ),
    );

    expect(
      find.descendant(
        of: find.byType(HostSwitcherBar),
        matching: find.byType(CompanionTouchRow),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ConnectionsSection),
        matching: find.byType(CompanionTouchRow),
      ),
      findsOneWidget,
    );
  });
}
