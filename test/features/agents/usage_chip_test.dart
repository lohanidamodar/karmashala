import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/application/usage_refresh_policy.dart';
import 'package:karmashala/src/features/agents/data/agent_usage_service.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_usage.dart';
import 'package:karmashala/src/features/agents/domain/usage_failure.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

class _Movable implements Clock {
  _Movable(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// The chip, in a tree, reading one container.
///
/// [visible] takes the chip out without taking the scope with it — the shape a
/// pane switch has. Unmounting the whole `UncontrolledProviderScope` instead
/// would prove nothing: Riverpod cancels its scheduled auto-dispose when the
/// surrounding scope goes, which is why `UsageChip.dispose` stops the timer
/// itself.
Widget chipIn(ProviderContainer container, {bool visible = true}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: visible ? const UsageChip() : const SizedBox.shrink(),
          ),
        ),
      ),
    );

/// **The four states the chip can be in**, and the rule that outranks all of
/// them: the number is always spelled out, so the colour is never the only
/// signal (`session_verdict_mark.dart` states it, and `CandidateStateMark` —
/// the last surface that broke it — now keeps it too).
void main() {
  late FakeAgentUsageService service;
  final light = SemanticColors.forBrightness(Brightness.light);

  setUp(() => service = FakeAgentUsageService());

  ProviderContainer containerFor({
    String agentId = AgentIds.claudeCode,
    Clock? clock,
  }) {
    final db = seedUsageDatabase(agentId: agentId);
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock ?? FixedClock(testTime)),
        agentUsageServiceProvider.overrideWithValue(service),
        // Settings opens on a tap; nothing here may probe a real machine.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    return container;
  }

  Future<ProviderContainer> pumpChip(
    WidgetTester tester, {
    String agentId = AgentIds.claudeCode,
    Clock? clock,
  }) async {
    final container = containerFor(agentId: agentId, clock: clock);
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    return container;
  }

  /// The policy owns a real periodic timer, and `testWidgets` fails a test that
  /// leaves one pending. Blur is the app's own way of cancelling it.
  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  String tooltipOf(WidgetTester tester) =>
      tester.widget<Tooltip>(find.byType(Tooltip)).message ?? '';

  Color? colourOf(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style?.color;

  testWidgets('draws the tightest window as a percent and a countdown', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);

    expect(find.text('62% · 2h11m'), findsOneWidget);
    expect(colourOf(tester, '62% · 2h11m'), light.idle);
    expect(
      tester.widget<Icon>(find.byIcon(AppIcons.circleHalf)).color,
      light.idle,
      reason: 'the gauge glyph carries the same tone as the number',
    );

    final tip = tooltipOf(tester);
    expect(tip, contains('5-hour · 62% · resets in 2h11m'));
    expect(tip, contains('7-day · 1% · resets in 3d'));
    expect(tip, contains('owner@example.com'));
    expect(tip, contains('Checked just now'));
    await quiesce(tester, container);
  });

  testWidgets('shows the window nearest its limit, not the first one', (
    tester,
  ) async {
    // A fresh 5-hour window and a nearly-spent weekly cap: the weekly one is
    // what will actually stop you, and the chip has room for one number.
    service.answer = AgentUsage(
      windows: [
        UsageWindow(
          label: '5-hour',
          percent: 4,
          resetsAt: testTime.add(const Duration(hours: 1)),
        ),
        UsageWindow(
          label: '7-day',
          percent: 97,
          resetsAt: testTime.add(const Duration(days: 2)),
        ),
      ],
      fetchedAt: testTime,
    );
    final container = await pumpChip(tester);

    expect(find.text('97% · 2d'), findsOneWidget);
    expect(colourOf(tester, '97% · 2d'), light.failure);
    await quiesce(tester, container);
  });

  for (final (percent, tone, expected) in <(double, String, Color)>[
    (62, 'healthy', SemanticColors.forBrightness(Brightness.light).idle),
    (
      kUsageWarningPercent,
      'warning',
      SemanticColors.forBrightness(Brightness.light).attention,
    ),
    (
      kUsageCriticalPercent,
      'critical',
      SemanticColors.forBrightness(Brightness.light).failure,
    ),
  ]) {
    testWidgets('at ${percent.round()}% the chip reads $tone, and still spells '
        'the number out', (tester) async {
      service.answer = usageSnapshot(percent: percent);
      final container = await pumpChip(tester);

      final label = '${percent.round()}% · 2h11m';
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'state is never carried by colour alone',
      );
      expect(colourOf(tester, label), expected);
      await quiesce(tester, container);
    });
  }

  testWidgets('is absent entirely for an agent we have no endpoint for', (
    tester,
  ) async {
    final container = await pumpChip(tester, agentId: AgentIds.antigravity);

    expect(find.byType(UsageChip), findsOneWidget);
    expect(
      find.byIcon(AppIcons.circleHalf),
      findsNothing,
      reason: 'not an error and not a placeholder — nothing at all',
    );
    expect(find.byType(Tooltip), findsNothing);
    expect(
      service.calls,
      isEmpty,
      reason: 'an agent with no usage endpoint is never asked',
    );
    await quiesce(tester, container);
  });

  testWidgets('an expired token mutes the chip and never raises a SnackBar', (
    tester,
  ) async {
    service.failure = UsageException(
      'Access token expired. Run the agent once to refresh, then retry.',
    );
    final container = await pumpChip(tester);

    expect(find.text('usage —'), findsOneWidget);
    expect(colourOf(tester, 'usage —'), light.neutral);
    expect(
      find.byIcon(AppIcons.question),
      findsOneWidget,
      reason: 'nothing was measured, so the gauge glyph is not drawn — the '
          'same answer HealthLevel.unknown gives one panel over',
    );
    expect(find.byIcon(AppIcons.circleHalf), findsNothing);
    expect(
      tooltipOf(tester),
      'Access token expired. Run the agent once to refresh, then retry.',
      reason: "the service's own sentence, verbatim",
    );
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'a stale token would nag once a minute',
    );
    await quiesce(tester, container);
  });

  testWidgets('a failed refresh keeps the number it had, and says it is old', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);
    expect(find.text('62% · 2h11m'), findsOneWidget);

    // Offline behaves exactly like any other failed fetch.
    service.failure = UsageException(
      'Could not reach the usage service: SocketException',
    );
    container.read(usageRefreshProvider.notifier).refresh();
    await tester.pump();
    await tester.pump();

    expect(
      find.text('62% · 2h11m'),
      findsOneWidget,
      reason: 'losing a number you had is worse than an old one that admits it',
    );
    final tip = tooltipOf(tester);
    expect(tip, contains('Last checked just now'));
    expect(
      tip,
      contains('Refresh failed: Could not reach the usage service'),
    );
    expect(find.byType(SnackBar), findsNothing);
    await quiesce(tester, container);
  });

  testWidgets('a rate limit keeps the number, and says how long it is '
      'waiting', (tester) async {
    service.answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);
    expect(find.text('62% · 2h11m'), findsOneWidget);

    // What the endpoint actually sent the owner. The service turns it into a
    // wait; the chip's job is to keep the number and explain the pause.
    service.failure = UsageException(
      'Rate limited by the usage service.',
      kind: UsageFailureKind.rateLimited,
    );
    container.read(usageRefreshProvider.notifier).refresh();
    await tester.pump();
    await tester.pump();

    expect(find.text('62% · 2h11m'), findsOneWidget);
    final tip = tooltipOf(tester);
    expect(tip, contains('Last checked just now'));
    expect(tip, contains('Rate limited by the usage service'));
    expect(tip, contains('Waiting 1m'));
    expect(
      tip,
      isNot(contains('Refresh failed')),
      reason: 'a rate limit is not a failure the user should act on',
    );
    expect(
      find.byIcon(AppIcons.clockCounterClockwise),
      findsOneWidget,
      reason: 'a number that was not confirmed is drawn as a reading with an '
          'age, not as a live gauge',
    );

    // And the poll stops spending requests on a limit it has been told about —
    // the whole bug: 60 requests an hour into an endpoint that was refusing.
    final spent = service.calls.length;
    container.read(usageRefreshProvider.notifier).refresh();
    await tester.pump();
    await tester.pump();
    expect(service.calls.length, spent, reason: 'the backoff is in force');
    expect(find.text('62% · 2h11m'), findsOneWidget);
    await quiesce(tester, container);
  });

  testWidgets('a number the app already read survives the chip leaving the '
      'tree', (tester) async {
    // The reported symptom: the status bar showed nothing. `AsyncValue` carries
    // a previous value through a refresh, but not through the autoDispose that
    // a pane switch causes — and the first failure after coming back then had
    // nothing to fall back on.
    final clock = _Movable(testTime);
    service = FakeAgentUsageService(clock: clock)
      ..answer = usageSnapshot(percent: 62);
    final container = containerFor(clock: clock);
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    expect(find.text('62% · 2h11m'), findsOneWidget);

    // A millisecond, because Riverpod's auto-dispose is scheduled rather than
    // immediate: without it the provider is still alive and the remount proves
    // nothing about what a real pane switch does.
    await tester.pumpWidget(chipIn(container, visible: false));
    await tester.pump(const Duration(milliseconds: 1));
    clock.now = clock.now.add(const Duration(minutes: 5));
    service.failure = UsageException(
      'Could not reach the usage service: SocketException',
      kind: UsageFailureKind.unreachable,
    );
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('62% · 2h6m'),
      findsOneWidget,
      reason: 'the number it read five minutes ago, counted down honestly',
    );
    final tip = tooltipOf(tester);
    expect(tip, contains('Last checked 5m ago'));
    expect(tip, contains('Refresh failed: Could not reach the usage service'));
    expect(find.byIcon(AppIcons.clockCounterClockwise), findsOneWidget);
    await quiesce(tester, container);
  });

  testWidgets('coming back inside one interval costs no request at all', (
    tester,
  ) async {
    service.answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);
    expect(service.calls.length, 1);

    // A pane switch away and back. Every one of these used to be a request,
    // bounded by nothing — the trigger the poll interval never covered.
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(chipIn(container, visible: false));
      // Long enough for Riverpod's scheduled auto-dispose to actually run, so
      // the chip really is rebuilt from nothing each time round.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpWidget(chipIn(container));
      await tester.pump();
    }

    expect(find.text('62% · 2h11m'), findsOneWidget);
    expect(
      service.calls.length,
      1,
      reason: 'five switches, and the reading was seconds old every time',
    );
    await quiesce(tester, container);
  });

  testWidgets('clicking refreshes and opens the usage view Settings already '
      'has', (tester) async {
    service.answer = usageSnapshot();
    final container = await pumpChip(tester);
    final before = service.calls.length;

    await tester.tap(find.byIcon(AppIcons.circleHalf));
    await tester.pumpAndSettle();

    expect(service.calls.length, before + 1, reason: 'a click is a refresh');
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('USAGE & LIMITS'), findsOneWidget);
    await quiesce(tester, container);
  });

  group('usageChipViewFor', () {
    test('is muted while the first answer is still in flight', () {
      final view = usageChipViewFor(const AsyncLoading(), testTime);
      expect(view.tone, UsageTone.muted);
      expect(view.label, 'usage …');
      expect(
        view.mark,
        UsageMark.live,
        reason: 'a read that has not answered yet is not a claim about it',
      );
    });

    test('claims nothing when it never got a number', () {
      final view = usageChipViewFor(
        AsyncError(UsageException('nope'), StackTrace.empty),
        testTime,
      );
      expect(view.mark, UsageMark.unknown);
      expect(view.label, 'usage —', reason: 'a dash, never a zero');
    });

    test('is muted, not coloured, when a fetch reported no windows', () {
      final view = usageChipViewFor(
        AsyncData(AgentUsage(windows: const [], fetchedAt: testTime)),
        testTime,
      );
      expect(view.tone, UsageTone.muted);
      expect(view.tooltip, contains('No usage windows reported.'));
    });

    test('reports a window with no reset time as a bare percent', () {
      final view = usageChipViewFor(
        AsyncData(
          AgentUsage(
            windows: const [UsageWindow(label: 'Extra usage', percent: 12)],
            fetchedAt: testTime,
          ),
        ),
        testTime,
      );
      expect(view.label, '12%');
    });
  });

  group('formatUsageDuration', () {
    test('is compact enough for a status bar', () {
      expect(
        formatUsageDuration(const Duration(hours: 2, minutes: 11)),
        '2h11m',
      );
      expect(formatUsageDuration(const Duration(hours: 3)), '3h');
      expect(formatUsageDuration(const Duration(minutes: 45)), '45m');
      expect(
        formatUsageDuration(const Duration(days: 3, hours: 4)),
        '3d4h',
      );
      expect(formatUsageDuration(const Duration(days: 2)), '2d');
      expect(formatUsageDuration(Duration.zero), 'now');
      expect(formatUsageDuration(const Duration(minutes: -5)), 'now');
    });
  });
}
