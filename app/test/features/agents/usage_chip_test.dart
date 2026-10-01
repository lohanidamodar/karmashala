import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/agents/presentation/toolbar_usage_strip.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip_popover.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_tab_view.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show UsageFailure;

import '../../support/fakes.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// **Every provider the chip's tree caused to exist**, by name — the bill
/// `session_switch_cost_test.dart` counts the same way.
///
/// A second window drawn from the reading the chip already watches must cost
/// nothing: no provider per period, no second subscription, and above all no
/// second request. The set is compared rather than a magic number, so the test
/// says what it means without pinning the tree's unrelated furniture.
final class _Subscriptions extends ProviderObserver {
  final Set<String> names = {};

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    final provider = context.provider;
    final argument = provider.from == null ? '' : '(${provider.argument})';
    names.add('${provider.runtimeType}$argument');
  }
}

/// The account key the seeded workspace files its quota under:
/// `claudeCode@windows`.
final _claudeAccount = usageAccountKey(agentInstallation());

/// The chip, in a tree, reading one container.
///
/// [visible] takes the chip out without taking the scope with it — the shape a
/// pane switch has. Unmounting the whole `UncontrolledProviderScope` instead
/// would prove nothing: Riverpod cancels its scheduled auto-dispose when the
/// surrounding scope goes.
Widget chipIn(ProviderContainer container, {bool visible = true}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            // The toolbar's strip, as wide as a desktop toolbar leaves it.
            child: visible
                ? const SizedBox(width: 900, child: ToolbarUsageStrip())
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );

/// **The four states the chip can be in**, and the rule that outranks all of
/// them: the number is always spelled out, so the colour is never the only
/// signal (`session_verdict_mark.dart` states it, and `CandidateStateMark` —
/// the last surface that broke it — now keeps it too).
void main() {
  late MovableClock clock;
  late FakeDataServer server;
  final light = SemanticColors.forBrightness(Brightness.light);

  /// What the server last read of the seeded account, told to the app when
  /// the container is built: [answer], and how the last attempt failed.
  AgentUsage? answer;
  UsageFailure? failure;

  setUp(() {
    // The countdowns are drawn against this clock; a test that moves it moves
    // what "ago" and "resets in" say.
    clock = MovableClock(testTime);
    answer = usageSnapshot(fetchedAt: testTime);
    failure = null;
  });

  /// Tells the app the server's new state of the seeded account, as the
  /// server's own schedule would after a read.
  void serverRead({AgentUsage? usage, UsageFailure? failed, String? agentId}) =>
      seedUsage(
        server,
        agentInstallation(agentId: agentId ?? AgentIds.claudeCode),
        usage: usage,
        failure: failed,
      );

  Future<ProviderContainer> containerFor({
    String agentId = AgentIds.claudeCode,
    _Subscriptions? observer,
  }) async {
    final db = seedUsageDatabase(agentId: agentId);
    server = db.server;
    if (answer != null || failure != null) {
      serverRead(usage: answer, failed: failure, agentId: agentId);
    }
    final data = await db.server.override();
    final container = ProviderContainer(
      observers: [?observer],
      overrides: [
        data,
        clockProvider.overrideWithValue(clock),
        // Settings opens on a tap; nothing here may probe a real machine.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        // Opening the Settings **tab** builds the terminal controller, whose
        // real autosave is a periodic timer `testWidgets` refuses to leave
        // pending. Same stand-in as `fakeTerminalOverrides`, which this file
        // cannot spread whole — it already overrides the database and clock.
        scrollbackAutosaveFactoryProvider.overrideWithValue(
          ({required onTick}) => ScrollbackAutosave(
            onTick: onTick,
            schedule: (delay, callback) => Object(),
            cancel: (_) {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    return container;
  }

  Future<ProviderContainer> pumpChip(
    WidgetTester tester, {
    String agentId = AgentIds.claudeCode,
  }) async {
    final container = await containerFor(agentId: agentId);
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    return container;
  }

  /// Blurs the window at the end of a test, so nothing the focused app keeps
  /// running is left pending.
  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  /// The chip's sentence — what a screen reader is given, and what its card
  /// spells out.
  String tooltipOf(WidgetTester tester) {
    final chip = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics && (w.properties.label ?? '').contains(' usage: '),
      ),
    );
    final label = chip.properties.label!;
    return label.substring(label.indexOf(' usage: ') + ' usage: '.length);
  }

  Color? colourOf(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style?.color;

  /// The theme the toolbar is drawn in: a healthy short window is full ink,
  /// a healthy long one muted, and only a loud one wears its tone.
  ColorScheme schemeOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(ToolbarUsageStrip))).colorScheme;

  /// The seeded account's chip, by the key the strip gives it.
  Finder chipOf() => find.byKey(ValueKey('toolbar-usage-$_claudeAccount'));

  /// The two rings the chip draws before its numbers, when it has numbers.
  Finder gauge() => find.byWidgetPredicate(
    (w) =>
        w is CustomPaint &&
        w.painter.runtimeType.toString() == '_RingsPainter',
  );

  testWidgets('draws each period as a percent and a countdown', (tester) async {
    answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);

    // The title bar's chip (spec §4): the rings, then each window's number;
    // the countdowns are in its hover and its sentence.
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('1%'), findsOneWidget);
    expect(
      colourOf(tester, '62%'),
      light.attention,
      reason:
          '62% with 2h11m of the five hours left is on course to run out '
          'before it resets: amber (spec §4)',
    );
    expect(gauge(), findsOneWidget, reason: 'a measured account has rings');

    final tip = tooltipOf(tester);
    expect(tip, contains('5-hour · 62% · resets in 2h11m'));
    expect(tip, contains('7-day · 1% · resets in 3d'));
    expect(tip, contains('owner@example.com'));
    expect(tip, contains('Checked just now'));
    await quiesce(tester, container);
  });

  testWidgets('draws both periods, the shorter one first', (tester) async {
    // A fresh 5-hour window and a nearly-spent weekly cap. Neither answers for
    // the other — one says what stops you this afternoon, the other what stops
    // you this week — and the owner's reading of the row settled it: *"we have
    // enough space here, so let's show both the daily limit and weekly limit
    // together."*
    answer = AgentUsage(
      windows: [
        // Listed longest-first on purpose: the order on screen is the period's,
        // never the payload's.
        UsageWindow(
          label: '7-day',
          percent: 97,
          resetsAt: testTime.add(const Duration(days: 2)),
          span: kUsageSevenDayWindow,
        ),
        UsageWindow(
          label: '5-hour',
          percent: 4,
          resetsAt: testTime.add(const Duration(hours: 1)),
          span: kUsageFiveHourWindow,
        ),
      ],
      fetchedAt: testTime,
    );
    final container = await pumpChip(tester);

    expect(find.text('4%'), findsOneWidget);
    expect(find.text('97%'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('4%')).dx,
      lessThan(tester.getTopLeft(find.text('97%')).dx),
      reason: 'the shorter period is read first',
    );
    // Each number wears its own loudness (spec §4): a 4% that will not stop
    // anybody stays in plain ink, and the spent week is the one in red.
    expect(colourOf(tester, '4%'), schemeOf(tester).onSurface);
    expect(colourOf(tester, '97%'), light.failure);

    final tip = tooltipOf(tester);
    expect(tip, contains('5-hour · 4% · resets in 1h'));
    expect(tip, contains('7-day · 97% · resets in 2d'));
    expect(
      tip,
      contains(
        formatResetClock(testTime.add(const Duration(days: 2)), testTime),
      ),
      reason: 'each window keeps its own reset clock',
    );
    await quiesce(tester, container);
  });

  testWidgets('says nothing at all for a period it has no reading for', (
    tester,
  ) async {
    // One window and one only. The missing period is not a zero, not a dash and
    // not a second slot standing empty — `HealthLevel.unknown` is the same
    // answer to the same question one panel over.
    answer = AgentUsage(
      windows: [
        UsageWindow(
          label: '5-hour',
          percent: 62,
          resetsAt: testTime.add(const Duration(hours: 2, minutes: 11)),
          span: kUsageFiveHourWindow,
        ),
      ],
      fetchedAt: testTime,
    );
    final container = await pumpChip(tester);

    expect(find.text('62%'), findsOneWidget);
    expect(
      find.textContaining('%'),
      findsOneWidget,
      reason: 'one period known draws one fact, exactly as it always did',
    );
    expect(find.textContaining('0%'), findsNothing);
    await quiesce(tester, container);
  });

  testWidgets('falls back to the window nearest its limit when no period is '
      'named', (tester) async {
    // Paid overage and a model-scoped cap name no period the payload can place
    // on a scale, so neither can take a slot in the pair. When they are all
    // there is, the tightest of them answers alone — the rule the chip has
    // always had.
    answer = AgentUsage(
      windows: const [
        UsageWindow(label: 'Extra usage', percent: 12),
        UsageWindow(label: 'Opus', percent: 88),
      ],
      fetchedAt: testTime,
    );
    final container = await pumpChip(tester);

    expect(find.text('88%'), findsOneWidget);
    expect(find.textContaining('%'), findsOneWidget);
    expect(colourOf(tester, '88%'), light.attention);
    await quiesce(tester, container);
  });

  testWidgets('a window worse than both periods is what the chip shows', (
    tester,
  ) async {
    // The colour is the worst number the account has, and the chip must never
    // colour a number it does not show. A paid-overage window beating both
    // periods is the one case where the pair is not the whole story, and the
    // chip then says what it used to say.
    answer = AgentUsage(
      windows: [
        UsageWindow(
          label: '5-hour',
          percent: 4,
          resetsAt: testTime.add(const Duration(hours: 1)),
          span: kUsageFiveHourWindow,
        ),
        UsageWindow(
          label: '7-day',
          percent: 20,
          resetsAt: testTime.add(const Duration(days: 2)),
          span: kUsageSevenDayWindow,
        ),
        const UsageWindow(label: 'Extra usage', percent: 99),
      ],
      fetchedAt: testTime,
    );
    final container = await pumpChip(tester);

    expect(find.text('99%'), findsOneWidget);
    expect(find.textContaining('%'), findsOneWidget);
    expect(colourOf(tester, '99%'), light.failure);
    await quiesce(tester, container);
  });

  testWidgets('the second period costs nothing the first did not', (
    tester,
  ) async {
    // One period, then two, under one tree that never moves: the second window
    // arrives inside the reading the chip already watches, so it must not add a
    // provider, a subscription or a request.
    answer = AgentUsage(
      windows: [
        UsageWindow(
          label: '5-hour',
          percent: 62,
          resetsAt: testTime.add(const Duration(hours: 2, minutes: 11)),
          span: kUsageFiveHourWindow,
        ),
      ],
      fetchedAt: testTime,
    );
    final watched = _Subscriptions();
    final container = await containerFor(observer: watched);
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    expect(find.text('62%'), findsOneWidget);
    final one = {...watched.names};

    // The server's next reading names both periods.
    serverRead(usage: usageSnapshot(percent: 62, fetchedAt: clock.nowUtc()));
    await tester.pump();
    await tester.pump();

    expect(find.text('62%'), findsOneWidget);
    expect(find.text('1%'), findsOneWidget, reason: 'two facts now');
    expect(
      watched.names,
      one,
      reason: 'the second period is drawn from what was already watched',
    );
    expect(
      server.agentWork.refreshes,
      isEmpty,
      reason: 'a period is not a lookup — the app asked the server nothing',
    );
    await quiesce(tester, container);
  });

  for (final (percent, tone, expected) in <(double, String, Color)>[
    // Healthy is plain ink — the rings say it is fine; the colour is kept
    // for a number that needs looking at.
    (62, 'healthy', Colors.transparent),
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
      // Near the window's end, so pace is not what colours it: at 62% with
      // half an hour left the window finishes well inside its limit.
      answer = usageSnapshot(
        percent: percent,
        resetsIn: const Duration(minutes: 30),
      );
      final container = await pumpChip(tester);

      final label = '${percent.round()}%';
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'state is never carried by colour alone',
      );
      expect(
        colourOf(tester, label),
        expected == Colors.transparent ? schemeOf(tester).onSurface : expected,
      );
      await quiesce(tester, container);
    });
  }

  testWidgets('an Antigravity pane draws no number, because nothing measured '
      'one', (tester) async {
    // The bug this file's Antigravity case exists for: `loadCodeAssist` names
    // the account's tiers and reports no quota, and the parser used to turn
    // each tier into `percent: 0.0`. The chip then spelled out a confident
    // `0%` — the most alarming reading there is — for something nobody had
    // read. It now says what it says for any unmeasured thing.
    answer = antigravitySnapshot();
    final container = await pumpChip(tester, agentId: AgentIds.antigravity);

    expect(find.text('—'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing, reason: 'not 0%, not any %');
    expect(colourOf(tester, '—'), schemeOf(tester).onSurfaceVariant);
    expect(
      find.byIcon(AppIcons.question),
      findsOneWidget,
      reason: 'the glyph claims what the label does: nothing was observed',
    );
    expect(gauge(), findsNothing);

    // And the tooltip says everything that *is* known.
    final tip = tooltipOf(tester);
    expect(tip, contains('No quota reported for this account.'));
    expect(tip, contains('Gemini Code Assist · no quota reported'));
    expect(tip, contains('dev@google.com'));
    expect(
      tip,
      contains(
        'Sign-in expires in 3h '
        '(${formatResetClock(testTime.add(const Duration(hours: 3)), testTime)})',
      ),
      reason: 'the token expiry is a fact, and it is not a quota reset',
    );
    expect(tip, contains('Checked just now'));
    await quiesce(tester, container);
  });

  testWidgets('an account the server never read draws nothing at all', (
    tester,
  ) async {
    // An agent with no usage endpoint is one the server never reads.
    answer = null;
    final container = await pumpChip(tester, agentId: 'unknownAgent');

    expect(find.byType(ToolbarUsageStrip), findsOneWidget);
    expect(
      chipOf(),
      findsNothing,
      reason: 'not an error and not a placeholder — nothing at all',
    );
    expect(
      server.agentWork.refreshes,
      isEmpty,
      reason: 'an agent with no usage endpoint is never asked',
    );
    await quiesce(tester, container);
  });

  testWidgets('an expired token mutes the chip and never raises a SnackBar', (
    tester,
  ) async {
    answer = null;
    failure = const UsageFailure(
      message:
          'Access token expired. Run the agent once to refresh, then retry.',
      kind: UsageFailureKind.auth,
    );
    final container = await pumpChip(tester);

    expect(find.text('—'), findsOneWidget);
    expect(colourOf(tester, '—'), schemeOf(tester).onSurfaceVariant);
    expect(
      find.byIcon(AppIcons.question),
      findsOneWidget,
      reason:
          'nothing was measured, so the gauge glyph is not drawn — the '
          'same answer HealthLevel.unknown gives one panel over',
    );
    expect(gauge(), findsNothing);
    expect(
      tooltipOf(tester),
      'Access token expired. Run the agent once to refresh, then retry.',
      reason: "the server's own sentence, verbatim",
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
    answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);
    expect(find.text('62%'), findsOneWidget);

    // Offline behaves exactly like any other failed fetch: the server keeps
    // the reading it had and tells the attempt's failure beside it.
    clock.now = clock.now.add(usageFixtureFloor);
    serverRead(
      usage: answer,
      failed: const UsageFailure(
        message: 'Could not reach the usage service: SocketException',
        kind: UsageFailureKind.unreachable,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('62%'),
      findsOneWidget,
      reason: 'losing a number you had is worse than an old one that admits it',
    );
    final tip = tooltipOf(tester);
    expect(tip, contains('5-hour · 62% · resets in 2h8m'));
    expect(tip, contains('Last checked 3m ago'));
    expect(tip, contains('Refresh failed: Could not reach the usage service'));
    expect(find.byType(SnackBar), findsNothing);
    await quiesce(tester, container);
  });

  testWidgets('a rate limit keeps the number, and says how long it is '
      'waiting', (tester) async {
    answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);
    expect(find.text('62%'), findsOneWidget);

    // What the endpoint actually sent the owner. The server turns it into a
    // wait, in its own words; the chip's job is to keep the number and explain
    // the pause.
    clock.now = clock.now.add(usageFixtureFloor);
    serverRead(
      usage: answer,
      failed: UsageFailure(
        message:
            'Rate limited by the usage service. Waiting 1m before asking '
            'again.',
        kind: UsageFailureKind.rateLimited,
        until: clock.now.add(const Duration(minutes: 1)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('62%'), findsOneWidget);
    final tip = tooltipOf(tester);
    expect(tip, contains('5-hour · 62% · resets in 2h8m'));
    expect(tip, contains('Last checked 3m ago'));
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
      reason:
          'a number that was not confirmed is drawn as a reading with an '
          'age, not as a live gauge',
    );
    await quiesce(tester, container);
  });

  testWidgets('a number the app already read survives the chip leaving the '
      'tree', (tester) async {
    // The reported symptom: the status bar showed nothing. `AsyncValue` carries
    // a previous value through a refresh, but not through the autoDispose that
    // a pane switch causes — and the first failure after coming back then had
    // nothing to fall back on.
    answer = usageSnapshot(percent: 62);
    final container = await containerFor();
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    expect(find.text('62%'), findsOneWidget);

    // A millisecond, because Riverpod's auto-dispose is scheduled rather than
    // immediate: without it the provider is still alive and the remount proves
    // nothing about what a real pane switch does.
    await tester.pumpWidget(chipIn(container, visible: false));
    await tester.pump(const Duration(milliseconds: 1));
    clock.now = clock.now.add(const Duration(minutes: 5));
    serverRead(
      usage: answer,
      failed: const UsageFailure(
        message: 'Could not reach the usage service: SocketException',
        kind: UsageFailureKind.unreachable,
      ),
    );
    await tester.pumpWidget(chipIn(container));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('62%'),
      findsOneWidget,
      reason: 'the number it read five minutes ago',
    );
    final tip = tooltipOf(tester);
    expect(
      tip,
      contains('5-hour · 62% · resets in 2h6m'),
      reason: 'and its countdown, counted down honestly',
    );
    expect(tip, contains('Last checked 5m ago'));
    expect(tip, contains('Refresh failed: Could not reach the usage service'));
    expect(find.byIcon(AppIcons.clockCounterClockwise), findsOneWidget);
    await quiesce(tester, container);
  });

  testWidgets('coming back to the pane asks the server nothing', (
    tester,
  ) async {
    // The server reads on its own schedule; a chip mounting only draws what
    // it was told. A pane switch used to be a request.
    answer = usageSnapshot(percent: 62);
    final container = await pumpChip(tester);

    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(chipIn(container, visible: false));
      // Long enough for Riverpod's scheduled auto-dispose to actually run, so
      // the chip really is rebuilt from nothing each time round.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpWidget(chipIn(container));
      await tester.pump();
    }

    expect(find.text('62%'), findsOneWidget);
    expect(
      server.agentWork.refreshes,
      isEmpty,
      reason: 'five switches, and not one ask',
    );
    await quiesce(tester, container);
  });

  testWidgets('clicking opens the account\'s card; its Refresh asks the '
      'server, and Usage settings opens the view Settings already has', (
    tester,
  ) async {
    answer = usageSnapshot();
    final container = await pumpChip(tester);

    await tester.tap(chipOf());
    await tester.pumpAndSettle();
    expect(find.byType(UsageChipPopover), findsOneWidget);
    expect(
      server.agentWork.refreshes,
      isEmpty,
      reason: 'opening the card reads nothing: the server keeps its schedule',
    );

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(
      server.agentWork.refreshes,
      [_claudeAccount],
      reason:
          'Refresh asks the server to read this account; its throttle '
          'decides whether that costs a request',
    );

    await tester.tap(find.byTooltip('Usage settings'));
    await tester.pumpAndSettle();
    expect(find.byType(UsageChipPopover), findsNothing);
    // Settings is a workbench tab now, so the click asks for a **page**
    // rather than pushing a route: it writes the section and opens the tab.
    final target = container.read(settingsTabSectionProvider);
    expect(target?.page, SettingsSectionId.accounts);
    expect(target?.anchor, SettingsAnchor.usage);
    // What that page then draws, mounted the way the tab draws it. The
    // workbench around it is `settings_tab_test`'s subject, not this file's.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsTabView()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('USAGE & LIMITS'), findsOneWidget);
    await quiesce(tester, container);
  });

  testWidgets('Usage settings again focuses the one Settings tab, however '
      'often', (tester) async {
    answer = usageSnapshot();
    final container = await pumpChip(tester);

    for (var i = 0; i < 5; i++) {
      await tester.tap(chipOf());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Usage settings'));
      await tester.pumpAndSettle();
      // Nothing to dismiss between clicks: the tab is already open, and the
      // second ask focuses it rather than stacking a second copy.
      expect(
        container
            .read(terminalSessionsControllerProvider)
            .tabs
            .where((tab) => tab.layout.panes.any(isSettingsPane)),
        hasLength(1),
      );
    }

    expect(
      server.agentWork.refreshes,
      isEmpty,
      reason: 'opening the card and the page read nothing',
    );
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

    test('orders the pair by period, not by the payload or by which resets '
        'soonest', () {
      // A weekly window resetting in twenty minutes is still the longer period.
      // Ordering by what resets soonest would swap the two at the end of every
      // week, which is when the row is read most carefully.
      final view = usageChipViewFor(
        AsyncData(
          AgentUsage(
            windows: [
              UsageWindow(
                label: '7-day',
                percent: 59,
                resetsAt: testTime.add(const Duration(minutes: 20)),
                span: kUsageSevenDayWindow,
              ),
              UsageWindow(
                label: '5-hour',
                percent: 12,
                resetsAt: testTime.add(const Duration(hours: 4)),
                span: kUsageFiveHourWindow,
              ),
            ],
            fetchedAt: testTime,
          ),
        ),
        testTime,
      );
      expect(view.label, '12% · 4h');
      expect(view.longLabel, '59% · 20m');
    });

    test('keeps the worst of several windows sharing a period', () {
      // Claude reports `seven_day`, `seven_day_opus` and `seven_day_sonnet`,
      // and a model-scoped weekly cap on top. One slot, so the one that will
      // actually stop you takes it.
      final view = usageChipViewFor(
        AsyncData(
          AgentUsage(
            windows: const [
              UsageWindow(
                label: '5-hour',
                percent: 12,
                span: kUsageFiveHourWindow,
              ),
              UsageWindow(
                label: '7-day',
                percent: 40,
                span: kUsageSevenDayWindow,
              ),
              UsageWindow(
                label: 'Opus · 7-day',
                percent: 91,
                span: kUsageSevenDayWindow,
              ),
            ],
            fetchedAt: testTime,
          ),
        ),
        testTime,
      );
      expect(view.label, '12%');
      expect(view.longLabel, '91%');
      expect(view.tone, UsageTone.warning);
    });

    test('offers no second fact when the reading names one period', () {
      final view = usageChipViewFor(
        AsyncData(
          AgentUsage(
            windows: const [
              UsageWindow(
                label: '5-hour',
                percent: 12,
                span: kUsageFiveHourWindow,
              ),
            ],
            fetchedAt: testTime,
          ),
        ),
        testTime,
      );
      expect(view.label, '12%');
      expect(
        view.longLabel,
        isNull,
        reason: 'an unread period says nothing rather than nothing-shaped',
      );
    });

    test('claims nothing when the reply measured nothing', () {
      // Antigravity's shape: windows the endpoint named, and no reading in any
      // of them. A successful fetch, so not an error — and still not a number.
      final view = usageChipViewFor(AsyncData(antigravitySnapshot()), testTime);
      expect(view.label, 'usage —', reason: 'a dash, never a zero');
      expect(view.longLabel, isNull);
      expect(view.tone, UsageTone.muted);
      expect(
        view.mark,
        UsageMark.unknown,
        reason: 'a gauge glyph would claim a measurement that was not taken',
      );
      expect(view.tooltip, contains('No quota reported for this account.'));
      expect(view.tooltip, isNot(contains('%')));
    });

    test('names a window with no reading in the tooltip, and never on the '
        'chip', () {
      // A reading that carries both. The measured window is the whole chip;
      // the unmeasured one is a line of the tooltip and nothing else — it
      // cannot take a slot, and it cannot take the colour.
      final view = usageChipViewFor(
        AsyncData(
          AgentUsage(
            windows: const [
              UsageWindow(
                label: '5-hour',
                percent: 12,
                span: kUsageFiveHourWindow,
              ),
              UsageWindow(label: 'Gemini Code Assist'),
            ],
            fetchedAt: testTime,
          ),
        ),
        testTime,
      );
      expect(view.label, '12%');
      expect(view.longLabel, isNull);
      expect(view.tone, UsageTone.healthy);
      expect(view.mark, UsageMark.live);
      expect(view.tooltip, contains('5-hour · 12%'));
      expect(view.tooltip, contains('Gemini Code Assist · no quota reported'));
      expect(
        view.tooltip,
        isNot(contains('Gemini Code Assist · 0%')),
        reason: 'the line that used to be here is the whole bug',
      );
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
      expect(formatUsageDuration(const Duration(days: 3, hours: 4)), '3d4h');
      expect(formatUsageDuration(const Duration(days: 2)), '2d');
      expect(formatUsageDuration(Duration.zero), 'now');
      expect(formatUsageDuration(const Duration(minutes: -5)), 'now');
    });
  });
}
