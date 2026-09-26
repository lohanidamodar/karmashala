import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala/src/features/settings/presentation/agent_usage_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AccountUsageState, UsageFailure;

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../agents/usage_fixtures.dart';
import '../../support/test_machine.dart';

/// **Why there is no number, in words the user can act on.**
///
/// A rate limit, an expired token and an unreachable endpoint used to arrive
/// here as one red sentence. They need three different responses — stop asking,
/// run the agent once, do nothing — so the card says which it is, and keeps the
/// last reading with its age underneath.
void main() {
  late TestMachine db;
  late MovableClock clock;

  /// What the server's read of the account answers when the card asks: the
  /// reading it holds, and how its latest attempt failed.
  AgentUsage? answer;
  UsageFailure? failure;

  final installation = agentInstallation();

  UsageFailure failed(
    String message, {
    UsageFailureKind kind = UsageFailureKind.unusable,
    DateTime? until,
  }) => UsageFailure(message: message, kind: kind, until: until);

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
    clock = MovableClock(testTime);
    answer = null;
    failure = null;
    db.server.agentWork.onRefresh = (key) => AccountUsageState(
      accountKey: key,
      agentId: installation.agentId,
      environmentId: installation.environmentId,
      usage: answer,
      failure: failure,
    );
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          clockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: UsageSection(installations: [installation]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> check(WidgetTester tester) async {
    await tester.tap(find.textContaining('Check usage'));
    await tester.pump();
    await tester.pump();
  }

  Color? colourOf(WidgetTester tester, IconData icon) =>
      tester.widget<Icon>(find.byIcon(icon)).color;

  testWidgets('a tier the endpoint reports no quota for says so, and draws no '
      'bar', (tester) async {
    // Antigravity's `loadCodeAssist` names the account's tiers and measures
    // nothing. The card used to draw a bar sitting at 0% for each of them,
    // which is a quantity — and the most reassuring one there is.
    answer = antigravitySnapshot();
    await pump(tester);
    await check(tester);

    expect(find.text('Gemini Code Assist'), findsOneWidget);
    expect(find.text('no quota reported'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'an empty bar reads as an empty quota',
    );
    // And the one time the reply does carry, said as itself.
    expect(find.text('Sign-in expires in 3h'), findsOneWidget);
  });

  testWidgets('a reset is counted down on the app clock, not the wall clock', (
    tester,
  ) async {
    // The test clock is months from the real date. A countdown read against
    // `DateTime.now()` says the reset already passed ("soon").
    answer = usageSnapshot(percent: 62);
    await pump(tester);
    await check(tester);

    expect(find.textContaining('resets in 2h11m'), findsOneWidget);
    expect(find.textContaining('resets soon'), findsNothing);
  });

  testWidgets('a 429 is a wait, and is not drawn as a fault', (tester) async {
    // The server's refusal, in its own words.
    failure = failed(
      'Rate limited by the usage service. Waiting 1m before asking again.',
      kind: UsageFailureKind.rateLimited,
      until: testTime.add(const Duration(minutes: 1)),
    );
    await pump(tester);
    await check(tester);

    expect(find.text('Rate limited'), findsOneWidget);
    expect(
      find.text(
        'Rate limited by the usage service. Waiting 1m before asking again.',
      ),
      findsOneWidget,
      reason: 'the sentence says what to do: nothing, for one minute',
    );
    expect(
      colourOf(tester, AppIcons.pauseCircle),
      SemanticColors.forBrightness(Brightness.light).attention,
      reason: 'nothing is broken, so nothing is red',
    );
  });

  testWidgets('the card opens saying why the number is not moving', (
    tester,
  ) async {
    // The user opens Settings *because* the chip stopped moving. A card that
    // said nothing would be the two surfaces disagreeing about one account.
    seedUsage(
      db.server,
      installation,
      failure: failed(
        'Rate limited by the usage service. Waiting 40s before asking again.',
        kind: UsageFailureKind.rateLimited,
        until: testTime.add(const Duration(minutes: 1)),
      ),
    );
    clock.now = clock.now.add(const Duration(seconds: 20));

    await pump(tester);

    expect(find.text('Rate limited'), findsOneWidget);
    expect(
      find.text(
        'Rate limited by the usage service. Waiting 40s before asking again.',
      ),
      findsOneWidget,
      reason: "the server's pause, in its words, while it is still in force",
    );
  });

  testWidgets('an expired token asks the user to run the agent', (
    tester,
  ) async {
    failure = failed(
      'Access token expired. Run the agent once to refresh, then retry.',
      kind: UsageFailureKind.auth,
    );
    await pump(tester);
    await check(tester);

    expect(find.text('Sign-in needed'), findsOneWidget);
    expect(
      find.text(
        'Access token expired. Run the agent once to refresh, '
        'then retry.',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(AppIcons.userCircle), findsOneWidget);
    expect(
      find.text('Rate limited'),
      findsNothing,
      reason: 'the two need opposite responses and must never read alike',
    );
  });

  testWidgets('an endpoint that never answered is nobody\'s fault', (
    tester,
  ) async {
    failure = failed(
      'Could not reach the usage service: SocketException',
      kind: UsageFailureKind.unreachable,
    );
    await pump(tester);
    await check(tester);

    expect(find.text('Could not reach the usage service'), findsOneWidget);
    expect(
      colourOf(tester, AppIcons.linkBreak),
      SemanticColors.forBrightness(Brightness.light).neutral,
      reason: 'offline is not an error the user made',
    );
  });

  testWidgets('a failed check keeps the bars, and says how old they are', (
    tester,
  ) async {
    answer = usageSnapshot(percent: 62);
    await pump(tester);
    await check(tester);
    expect(find.textContaining('62%'), findsOneWidget);
    expect(find.text('Checked just now'), findsOneWidget);

    clock.now = clock.now.add(const Duration(minutes: 4));
    failure = failed(
      'Could not reach the usage service: SocketException',
      kind: UsageFailureKind.unreachable,
    );
    await tester.tap(find.textContaining('Refresh'));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('62%'),
      findsOneWidget,
      reason: 'losing a number you had is worse than an old one that admits it',
    );
    expect(find.text('Checked 4m ago'), findsOneWidget);
    expect(find.text('Could not reach the usage service'), findsOneWidget);
  });

  testWidgets('the card opens on what was already read, and asks nothing', (
    tester,
  ) async {
    // The server's own read, a minute before Settings was opened.
    seedUsage(db.server, installation, usage: usageSnapshot(percent: 62));
    clock.now = clock.now.add(const Duration(minutes: 1));

    await pump(tester);

    expect(
      find.textContaining('62%'),
      findsOneWidget,
      reason: 'a blank card was hiding a number the app was holding',
    );
    expect(find.text('Checked 1m ago'), findsOneWidget);
    expect(
      db.server.agentWork.refreshes,
      isEmpty,
      reason: 'opening a panel is not a reason to ask for a read',
    );
    expect(find.textContaining('Refresh'), findsOneWidget);
  });
}
