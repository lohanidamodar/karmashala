import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_usage_service.dart';
import 'package:karmashala/src/features/agents/domain/usage_failure.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/presentation/agent_usage_section.dart';

import '../../support/fixtures.dart';
import '../agents/usage_fixtures.dart';

class _Movable implements Clock {
  _Movable(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// **Why there is no number, in words the user can act on.**
///
/// A rate limit, an expired token and an unreachable endpoint used to arrive
/// here as one red sentence. They need three different responses — stop asking,
/// run the agent once, do nothing — so the card says which it is, and keeps the
/// last reading with its age underneath.
void main() {
  late AppDatabase db;
  late _Movable clock;
  late FakeAgentUsageService service;

  final installation = agentInstallation();

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    clock = _Movable(testTime);
    service = FakeAgentUsageService(clock: clock);
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
          agentUsageServiceProvider.overrideWithValue(service),
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

  testWidgets('a 429 is a wait, and is not drawn as a fault', (tester) async {
    service.failure = UsageException(
      'Rate limited by the usage service.',
      kind: UsageFailureKind.rateLimited,
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

    // And the button no longer spends a request on a limit it knows about.
    final spent = service.calls.length;
    await tester.tap(find.textContaining('Check usage'));
    await tester.pump();
    await tester.pump();
    expect(service.calls.length, spent);
  });

  testWidgets('the card opens saying why the number is not moving', (
    tester,
  ) async {
    // The user opens Settings *because* the chip stopped moving. A card that
    // said nothing would be the two surfaces disagreeing about one account.
    service.failure = UsageException(
      'Rate limited by the usage service.',
      kind: UsageFailureKind.rateLimited,
    );
    await expectLater(
      () => service.fetch(installation, const []),
      throwsA(isA<UsageException>()),
    );
    clock.now = clock.now.add(const Duration(seconds: 20));

    await pump(tester);

    expect(find.text('Rate limited'), findsOneWidget);
    expect(
      find.text(
        'Rate limited by the usage service. Waiting 40s before asking again.',
      ),
      findsOneWidget,
      reason: 'the countdown is read now, not when the refusal arrived',
    );
  });

  testWidgets('an expired token asks the user to run the agent', (
    tester,
  ) async {
    service.failure = UsageException(
      'Access token expired. Run the agent once to refresh, then retry.',
      kind: UsageFailureKind.auth,
    );
    await pump(tester);
    await check(tester);

    expect(find.text('Sign-in needed'), findsOneWidget);
    expect(
      find.text('Access token expired. Run the agent once to refresh, '
          'then retry.'),
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
    service.failure = UsageException(
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
    service.answer = usageSnapshot(percent: 62);
    await pump(tester);
    await check(tester);
    expect(find.textContaining('62%'), findsOneWidget);
    expect(find.text('Checked just now'), findsOneWidget);

    clock.now = clock.now.add(const Duration(minutes: 4));
    service.failure = UsageException(
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
    service.answer = usageSnapshot(percent: 62);
    // The chip's own read, a minute before Settings was opened.
    await service.fetch(installation, const []);
    expect(service.calls.length, 1);
    clock.now = clock.now.add(const Duration(minutes: 1));

    await pump(tester);

    expect(
      find.textContaining('62%'),
      findsOneWidget,
      reason: 'a blank card was hiding a number the app was holding',
    );
    expect(find.text('Checked 1m ago'), findsOneWidget);
    expect(
      service.calls.length,
      1,
      reason: 'opening a panel is not a reason to spend a request',
    );
    expect(find.textContaining('Refresh'), findsOneWidget);
  });
}
