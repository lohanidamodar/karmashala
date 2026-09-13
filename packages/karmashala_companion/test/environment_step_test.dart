/// **Which machine, before which project — and only when there is a choice.**
///
/// The owner's rule, verbatim: *"then environment if host has multiple
/// environment, if only one skip"*. So the step has to earn its tap, and the
/// case that must never regress is the single-machine desktop, where the step
/// would be a screen offering one row.
library;

import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  List<CompanionSessionSummary> across() => [
    summary('s1', project: 'popupbits', projectId: 'p1',
        status: CompanionSessionStatus.idle,
        environmentId: 'windows', environmentBadge: 'Windows',
        environmentKind: 'windowsNative'),
    summary('s2', project: 'content', projectId: 'p2',
        status: CompanionSessionStatus.idle,
        environmentId: 'windows', environmentBadge: 'Windows',
        environmentKind: 'windowsNative'),
    summary('s3', title: 'On the droplet', project: 'Test ssh', projectId: 'p3',
        status: CompanionSessionStatus.idle,
        environmentId: 'ssh:h1', environmentBadge: 'do-box',
        environmentKind: 'ssh'),
  ];

  testWidgets('two machines are offered before any project', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(sessions: across()),
      home: const SessionListScreen(),
    );

    expect(find.byType(EnvironmentIndex), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(find.text('do-box'), findsOneWidget);
    expect(find.text('2 projects'), findsOneWidget);
    expect(find.text('1 project'), findsOneWidget);
    expect(
      find.text('popupbits'),
      findsNothing,
      reason: 'the machines come first; their projects are a tap away',
    );
  });

  testWidgets('picking one shows its projects and the way back', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(sessions: across()),
      home: const SessionListScreen(),
    );

    await tester.tap(find.text('do-box'));
    await tester.pumpAndSettle();

    expect(find.byType(EnvironmentIndex), findsNothing);
    expect(find.text('On the droplet'), findsOneWidget);
    expect(
      find.text('popupbits'),
      findsNothing,
      reason: 'the other machine is not on this screen',
    );

    await tester.tap(find.text('All machines'));
    await tester.pumpAndSettle();
    expect(find.byType(EnvironmentIndex), findsOneWidget);
  });

  testWidgets('one machine is no choice, so there is no step', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        sessions: [
          summary('s1', project: 'popupbits', projectId: 'p1',
              status: CompanionSessionStatus.idle,
              environmentId: 'windows', environmentBadge: 'Windows',
              environmentKind: 'windowsNative'),
          summary('s2', project: 'content', projectId: 'p2',
              status: CompanionSessionStatus.idle,
              environmentId: 'windows', environmentBadge: 'Windows',
              environmentKind: 'windowsNative'),
        ],
      ),
      home: const SessionListScreen(),
    );

    expect(find.byType(EnvironmentIndex), findsNothing);
    expect(find.text('popupbits'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('a desktop that names no machine shows projects as before', (
    tester,
  ) async {
    // An older desktop sends neither id nor badge. Nothing is derived from
    // that silence, so the phone behaves exactly as it did.
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        sessions: [
          summary('s1', project: 'popupbits', projectId: 'p1',
              status: CompanionSessionStatus.idle),
          summary('s2', project: 'content', projectId: 'p2',
              status: CompanionSessionStatus.idle),
        ],
      ),
      home: const SessionListScreen(),
    );

    expect(find.byType(EnvironmentIndex), findsNothing);
    expect(find.text('popupbits'), findsOneWidget);
  });

  testWidgets('a key from a desktop we left reads as all machines', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(sessions: across()),
      home: const SessionListScreen(),
    );
    ProviderScope.containerOf(tester.element(find.byType(SessionListScreen)))
        .read(companionEnvironmentProvider.notifier)
        .choose('ssh:some-other-desktop');
    await tester.pumpAndSettle();

    expect(
      find.byType(EnvironmentIndex),
      findsOneWidget,
      reason: 'a key naming nothing here must not empty the screen',
    );
  });
}
