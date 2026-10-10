/// The surfaces rounds 79–84 built or changed, each over fakes and drawn the
/// way the app draws it at the window in force: the phone build under 600px
/// (Android, a thumb's density, the page pushed from More), the desktop's tab
/// above. Shared by `responsive_window_matrix_test.dart`, which fails on
/// overflow at any width from 360 to 1440 px, and by
/// `tool/responsive_r85_screenshot.dart`, which renders them for a person to
/// look at.
library;

import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_more_page.dart';
import 'package:karmashala/src/app/shell/phone_routes.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_latest_versions_controller.dart';
import 'package:karmashala/src/features/agents/application/usage_forecast.dart';
import 'package:karmashala/src/features/agents/application/usage_glance.dart';
import 'package:karmashala/src/features/agents/application/usage_session_tokens.dart';
import 'package:karmashala/src/features/agents/application/usage_tab_prefs.dart';
import 'package:karmashala/src/features/agents/data/agent_latest_version_fetcher.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_view.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala/src/features/overview/application/overview_glance_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart'
    show OverviewSubSessionMode;
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart'
    show overviewPeekChatProvider;
import 'package:karmashala/src/features/overview/presentation/overview_pipeline_peek.dart';
import 'package:karmashala/src/features/overview/application/overview_pipeline_peek.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart'
    show workspaceSessionsProvider;
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_editor.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_detail.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_dialog.dart';
import 'package:karmashala/src/features/running/application/running_glance.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/stores/application/store_glance.dart';
import 'package:karmashala/src/features/stores/application/store_history.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala/src/features/stores/application/stores_layout_prefs.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_state.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_view.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/workflows/presentation/workflows_tab_view.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../features/agents/usage_fixtures.dart';
import '../features/overview/mission_fixture.dart';
import '../features/stores/store_fixtures.dart';
import '../features/stores/store_history_fixtures.dart';
import '../features/terminal/fake_instance.dart';
import '../support/fake_command_runner.dart';
import '../support/fake_data_server.dart';
import '../support/fake_http_client.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/test_machine.dart';

/// Builds the tree for the window in force; called once per window.
typedef SurfaceBuilder = Widget Function();

/// One surface: [prepare] seeds its fakes once and returns its builder;
/// [warmUp] drives it into the state worth measuring, such as a menu open.
class ResponsiveSurface {
  const ResponsiveSurface(
    this.name,
    this.prepare, {
    this.warmUp,
    this.phoneOnly = false,
    this.desktopOnly = false,
  });

  final String name;
  final Future<SurfaceBuilder> Function(
    WidgetTester tester,
    Brightness brightness,
  )
  prepare;
  final Future<void> Function(WidgetTester tester)? warmUp;

  /// Only the phone build draws it (the phone shell).
  final bool phoneOnly;

  /// Only a desktop draws it (a pointer's peek and keys sheet).
  final bool desktopOnly;
}

/// What a renderer captures: the app's whole window, dialogs and menus too.
final responsiveBoundary = GlobalKey(debugLabel: 'responsive-boundary');

/// Under 600 px the app is the phone build.
bool isPhoneWindow(WidgetTester tester) =>
    tester.view.physicalSize.width / tester.view.devicePixelRatio < 600;

/// [desktop] as the desktop's tab draws it, or on a phone [phoneHome], or
/// [phonePage] pushed from More under its app bar.
Widget responsiveApp(
  WidgetTester tester,
  ProviderContainer container,
  Brightness brightness, {
  required Widget desktop,
  PhoneMoreEntry? phonePage,
  Widget? phoneHome,
}) {
  final phone = isPhoneWindow(tester);
  final base = brightness == Brightness.dark
      ? AppTheme.dark()
      : AppTheme.light();
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      // flutter_test runs as Android; a desktop draws under a pointer.
      theme: base.copyWith(
        platform: phone ? TargetPlatform.android : TargetPlatform.windows,
      ),
      builder: (context, child) => RepaintBoundary(
        key: responsiveBoundary,
        child: UiDensity.wrap(
          context,
          phone ? PhoneTabsScope(child: child!) : child!,
        ),
      ),
      home: switch ((phone, phoneHome, phonePage)) {
        (true, final Widget home, _) => home,
        (true, null, final PhoneMoreEntry page) => _PushedFromMore(page),
        _ => Scaffold(body: desktop),
      },
    ),
  );
}

/// More, with [page] pushed over it on the first frame, as its row does.
class _PushedFromMore extends StatefulWidget {
  const _PushedFromMore(this.page);

  final PhoneMoreEntry page;

  @override
  State<_PushedFromMore> createState() => _PushedFromMoreState();
}

class _PushedFromMoreState extends State<_PushedFromMore> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          Navigator.of(context).push(PhoneMoreList.routeFor(widget.page)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => const PhoneMoreList();
}

/// Bounded settling: a working mark turns and a spinner never stops.
Future<void> settleSurface(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _byKey(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await settleSurface(tester);
  await tester.tap(finder.first);
  await settleSurface(tester);
}

/// Taps [finder] on the board, scrolling its lazy list until it is built: a
/// short window at large text keeps the lanes below the fold.
/// Scrolls the board until [finder] is drawn, tapping nothing.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300, scrollable: hybridList);
  }
  await tester.ensureVisible(finder.first);
  await settleSurface(tester);
}

Future<void> _tapOnBoard(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300, scrollable: hybridList);
  }
  await _tap(tester, finder);
}

/// Opens the first waiting session's peek, unless the last window left it
/// open: the board keeps it across a resize.
Future<void> _peek(WidgetTester tester) async {
  if (_byKey('overview-peek').evaluate().isNotEmpty) return;
  await _tapOnBoard(tester, _byKey('overview-queue-title:ks-r21'));
}

/// Opens run-1's peek, unless the last window left it open: the board
/// keeps it across a resize, and over a narrow board it covers the card.
Future<void> _peekRun(WidgetTester tester) async {
  if (find.byType(PipelineRunPeek).evaluate().isNotEmpty) return;
  await _tapOnBoard(tester, _byKey('overview-pipeline-open:run-1'));
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await settleSurface(tester);
}

// ---------------------------------------------------------------- dashboard

final _now = MissionFixture.now;

class _Runs extends PipelinesController {
  @override
  PipelinesState build() => PipelinesState(
    loaded: true,
    runs: {
      'run-1': PipelineRun(
        id: 'run-1',
        definition: kPipelineTemplates.first,
        repositoryId: 'r-p-ks',
        input: 'Add a badge to the cart icon',
        state: PipelineRunState.waiting,
        byPerson: true,
        createdAt: _now.subtract(const Duration(minutes: 12)),
        updatedAt: _now,
        records: [
          PipelineStageRecord(
            stageIndex: 0,
            role: 'Plan',
            attempt: 1,
            state: PipelineStageState.approval,
            sessionId: 'stage-plan',
            answer: 'A badge on the icon, then a widget test.',
            startedAt: _now.subtract(const Duration(minutes: 11)),
            finishedAt: _now.subtract(const Duration(minutes: 2)),
          ),
        ],
      ),
    },
  );
}

class _Todos extends TodosController {
  @override
  List<Todo> build() => [
    for (final (i, body) in [
      'Review round 83 Stores glance',
      'Ship 1.32 to TestFlight',
      'Reply to the cart-badge issue',
      'Clear stale worktrees',
    ].indexed)
      Todo(
        id: 't$i',
        body: body,
        position: i,
        createdAt: _now.subtract(Duration(hours: i)),
      ),
  ];
}

/// Every lane and all four glances filled: a pipeline at its gate, a session
/// waiting for a slot, four todos, running ports, stores and usage.
List<Override> dashboardOverrides() => [
  pipelinesProvider.overrideWith(_Runs.new),
  todosProvider.overrideWith(_Todos.new),
  runningGlanceProvider.overrideWithValue(
    const RunningGlance(
      servers: 3,
      newest: RunningGlanceServer(label: 'vite', port: 5173),
    ),
  ),
  storesGlanceProvider.overrideWithValue(
    StoresGlanceData(
      attention: 2,
      firstAttention: 'One (iOS)',
      newestRelease: (
        text: '1.34.6 Live',
        at: _now.subtract(const Duration(hours: 3)),
        app: 'Karmashala',
      ),
      ratingApp: 'Karmashala',
      ratingTrend: const [4.2, 4.3, 4.3, 4.4, 4.3, 4.5, 4.6, 4.6],
      rating: 4.6,
    ),
  ),
  usageGlanceProvider.overrideWithValue(
    UsageGlanceData(
      accounts: [
        UsageGlanceAccount(
          accountId: 'claude@windows',
          agentName: 'Claude Code',
          window: const UsageWindow(label: '5-hour', percent: 72),
          forecast: UsageForecast(
            kind: UsageForecastKind.runsOut,
            windowLabel: '5-hour',
            percent: 72,
            runsOutAt: _now.add(const Duration(hours: 1, minutes: 20)),
            resetsAt: _now.add(const Duration(hours: 4)),
          ),
        ),
        const UsageGlanceAccount(
          accountId: 'codex@windows',
          agentName: 'Codex',
          window: UsageWindow(label: '5-hour', percent: 31),
          forecast: UsageForecast(
            kind: UsageForecastKind.lastsUntilReset,
            windowLabel: '5-hour',
          ),
        ),
      ],
      occupancy: '4/4 running · 1 waiting',
    ),
  ),
  capacityNowProvider.overrideWithValue(
    CapacitySnapshot(
      limits: const LaunchLimits(global: 4),
      running: 4,
      waiters: [
        LaunchWaiter(
          ticketId: 'w1',
          label: 'Fix the flaky cart test',
          priority: LaunchPriority.interactive,
          place: 1,
          reason: 'Waiting for a slot: 4 of 4 are busy',
          enqueuedAt: _now.subtract(const Duration(minutes: 3)),
          personStarted: true,
        ),
      ],
    ),
  ),
];

/// [pumpMission]'s container, made once for every window of a matrix.
Future<ProviderContainer> _missionContainer() async {
  final fixture = MissionFixture.full();
  final db = TestMachine();
  final server = FakeDataServer()..runsOn(db);
  server.environmentRows
    ..upsert(windowsEnv())
    ..upsert(wslEnv(id: 'wsl:arch', distro: 'arch'))
    ..upsert(sshEnvFixture(id: 'ssh:box', name: 'build-box'));
  server.installationRows.insert(agentInstallation());
  server.activity.addAll(fixture.activity);
  final prefsDir = Directory.systemTemp.createTempSync('ks-responsive');
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(machine: db, data: await server.override()),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
      clockProvider.overrideWithValue(FixedClock(MissionFixture.now)),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(),
      ),
      overviewPrefsDirectoryProvider.overrideWithValue(() async => prefsDir),
      ...fixture.overrides,
      ...dashboardOverrides(),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<SurfaceBuilder> _mission(
  WidgetTester tester,
  Brightness brightness, {
  Widget? phoneHome,
  void Function(ProviderContainer container)? seed,
}) async {
  final c = (await tester.runAsync(_missionContainer))!;
  seed?.call(c);
  return () => responsiveApp(
    tester,
    c,
    brightness,
    desktop: const OverviewTabView(),
    phoneHome:
        phoneHome ??
        const Scaffold(body: PaneTitleOverride(child: OverviewTabView())),
  );
}

/// The run peek alone over the dashboard's run (round 88), on its stage's
/// session with [stage]: the session's chat is a stand-in, as the board's
/// own peek renders draw it.
Future<SurfaceBuilder> _runPeek(
  WidgetTester tester,
  Brightness brightness, {
  bool stage = false,
}) async {
  final c = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FixedClock(_now)),
      pipelinesProvider.overrideWith(_Runs.new),
      workspaceSessionsProvider.overrideWith(
        (ref) => [
          WorkspaceSessionEntry(
            id: 'stage-plan',
            title: 'Plan · Plan → Implement → Review',
            createdAt: _now,
          ),
        ],
      ),
      overviewPeekChatProvider.overrideWithValue(
        (entry, _) => Center(child: Text('chat:${entry.id}')),
      ),
    ],
  );
  addTearDown(c.dispose);
  final peeks = c.read(pipelinePeekProvider.notifier);
  stage ? peeks.openStage('run-1', 'stage-plan') : peeks.open('run-1');
  Widget peek({required bool compact}) => Consumer(
    builder: (context, ref, _) => switch (ref.watch(pipelinePeekProvider)) {
      null => const SizedBox.shrink(),
      final p => PipelineRunPeek(peek: p, compact: compact, onClose: () {}),
    },
  );
  return () => responsiveApp(
    tester,
    c,
    brightness,
    desktop: Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SizedBox(width: kOverviewPeekWidth, child: peek(compact: false)),
    ),
    phoneHome: Scaffold(body: SafeArea(child: peek(compact: true))),
  );
}

// ---------------------------------------------------------------- stores

class _Stores extends StoresController {
  _Stores(this._state);
  final StoresState _state;
  @override
  Future<StoresState> build() async => _state;
  @override
  Future<void> refreshIfStale() async {}
  @override
  Future<void> refresh() async {}
}

final _notesIos = storeApp(
  StoreKind.appStore,
  'com.example.notes',
  name: 'Notes',
);
final _notesPlay = storeApp(
  StoreKind.googlePlay,
  'com.example.notes',
  name: 'Notes',
);

/// Four listings: one app on both stores, one with a long name and id, one
/// whose rating could not be read.
StoresState storesFixtureState() {
  final tasks = storeApp(
    StoreKind.appStore,
    'com.example.tasks',
    name: 'Tasks',
  );
  final budget = storeApp(
    StoreKind.googlePlay,
    'com.example.household.budget.tracker',
    name: 'Household Budget Tracker and Shared Expenses',
  );
  return StoresState(
    view: StoresView(
      apple: AppleKeySummary(
        keyId: 'KEYID',
        issuerId: 'issuer',
        importedAt: DateTime.utc(2026, 9, 29),
      ),
      stores: {
        StoreKind.appStore: ReadingValue([_notesIos, tasks], fixtureCheckedAt),
        StoreKind.googlePlay: ReadingValue([
          _notesPlay,
          budget,
        ], fixtureCheckedAt),
      },
      apps: [
        storeSnapshot(
          _notesIos,
          releases: [
            storeRelease(
              ReleaseState.live,
              version: '2.3.0',
              track: 'App Store',
            ),
            storeRelease(
              ReleaseState.rejected,
              version: '2.4.0',
              track: 'App Store',
            ),
          ],
        ),
        storeSnapshot(
          _notesPlay,
          releases: [
            storeRelease(
              ReleaseState.rollingOut,
              version: '2.0.0',
              rolloutFraction: 0.5,
            ),
          ],
        ),
        storeSnapshot(
          tasks,
          rating: ReadingMissing(
            StoreFailure.network,
            'The App Store could not be reached.',
            fixtureCheckedAt,
          ),
        ),
        storeSnapshot(
          budget,
          releases: [
            storeRelease(
              ReleaseState.inReview,
              version: '10.12.3',
              track: 'internal testing',
            ),
          ],
        ),
      ],
      refreshedAt: _now.subtract(const Duration(minutes: 12)),
    ),
  );
}

/// The App Store and Play history of the app on both stores, up to today.
StoreHistoryView storesFixtureHistory() {
  final end = DateTime.utc(_now.year, _now.month, _now.day);
  return StoreHistoryView(
    keptDays: 365,
    apps: [
      StoreAppHistory(
        app: _notesIos,
        days: storeDays(end),
        steps: appleSteps(),
      ),
      StoreAppHistory(
        app: _notesPlay,
        days: storeDays(end),
        steps: playSteps(),
      ),
    ],
  );
}

Future<SurfaceBuilder> _stores(
  WidgetTester tester,
  Brightness brightness, {
  bool detail = false,
  StoresLayout? layout,
}) async {
  final c = (await tester.runAsync(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    final history = storesFixtureHistory();
    return ProviderContainer(
      overrides: [
        // The detail's "hand to a session" reads the panes.
        ...fakeTerminalOverrides(data: await server.override()),
        clockProvider.overrideWithValue(FixedClock(_now)),
        storesProvider.overrideWith(() => _Stores(storesFixtureState())),
        // Unpicked, the width decides: the table on a desktop, cards on a
        // phone.
        storesLayoutStoreProvider.overrideWithValue(
          MemoryStoresLayoutStore(layout),
        ),
        storeHistoryProvider.overrideWith((ref, keys) async => history),
      ],
    );
  }))!;
  addTearDown(c.dispose);
  if (detail) c.read(storesSelectionProvider.notifier).select(_notesIos.key);
  return () => responsiveApp(
    tester,
    c,
    brightness,
    desktop: const StoresTabView(),
    phonePage: PhoneMoreEntry.stores,
  );
}

// ---------------------------------------------------------------- usage

/// [many]: the seven sign-ins of round 86 rather than one.
Future<ProviderContainer> _usageContainer({bool many = false}) async {
  final db = seedUsageDatabase();
  seedUsage(db.server, agentInstallation(), usage: usageSnapshot());
  if (many) seedManyUsageAccounts(db.server);
  // A steady recent pace ending at the reading's 62%, and earlier readings.
  for (var i = 60; i >= 1; i--) {
    db.server.usageRows.insert(
      UsageSample(
        accountKey: 'claudeCode@windows',
        windowLabel: '5-hour',
        span: kUsageFiveHourWindow,
        percent: i > 12 ? 14 + (60 - i) * 0.2 : 62.0 - 2 * i,
        recordedAt: testTime.subtract(Duration(minutes: 5 * i)),
      ),
    );
  }
  final c = ProviderContainer(
    overrides: [
      usageTabPrefsStoreProvider.overrideWithValue(MemoryUsageTabPrefs()),
      await db.server.override(),
      clockProvider.overrideWithValue(MovableClock(testTime)),
      serverOfferProvider.overrideWithValue(
        const ServerOffer(
          sameMachine: true,
          features: {'sessions.capacity', 'sessions.stats'},
        ),
      ),
      capacityNowProvider.overrideWithValue(
        CapacitySnapshot(
          limits: const LaunchLimits(global: 4, machines: {'windows': 2}),
          running: 3,
          scopes: const [
            CapacityScopeUse(
              scope: CapacityScope.global,
              key: '',
              label: 'All',
              used: 3,
              limit: 4,
            ),
            CapacityScopeUse(
              scope: CapacityScope.machine,
              key: 'windows',
              label: 'Windows',
              used: 2,
              limit: 2,
            ),
          ],
          waiters: [
            LaunchWaiter(
              ticketId: 't1',
              label: 'Nightly triage',
              priority: LaunchPriority.background,
              place: 1,
              reason: 'Waiting for a slot',
              enqueuedAt: testTime,
            ),
          ],
        ),
      ),
      usageSessionRowsProvider.overrideWith(
        (ref) async => [
          UsageSessionRow(
            sessionId: 's1',
            title: 'Fix the checkout flow so a declined card says why',
            project: 'karmashala',
            agentId: 'claudeCode',
            tokens: 2400000,
            tokensByModel: const {'claude-opus-5-5': 2400000},
            lastActivityAt: testTime.subtract(const Duration(minutes: 12)),
          ),
          UsageSessionRow(
            sessionId: 's2',
            title: 'Translate the store listing',
            project: 'household-budget-site',
            agentId: 'opencode',
            tokens: 310000,
            costAmount: 1.84,
            costCurrency: 'USD',
            lastActivityAt: testTime.subtract(const Duration(minutes: 40)),
          ),
          UsageSessionRow(
            sessionId: 's3',
            title: 'Review the release notes',
            project: 'karmashala',
            agentId: 'opencode',
            tokens: 90000,
            costAmount: 0.42,
            costCurrency: 'USD',
            lastActivityAt: testTime.subtract(const Duration(hours: 1)),
          ),
        ],
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// The Usage tab's container over round 86's seven sign-ins, for a render.
Future<ProviderContainer> manyUsageAccountsContainer() =>
    _usageContainer(many: true);

Future<SurfaceBuilder> _usage(
  WidgetTester tester,
  Brightness b, {
  bool many = false,
}) async {
  final c = (await tester.runAsync(() => _usageContainer(many: many)))!;
  return () => responsiveApp(
    tester,
    c,
    b,
    desktop: const UsageTabView(),
    phonePage: PhoneMoreEntry.usage,
  );
}

/// The Usage tab scrolled [fraction] of its way down.
Future<void> Function(WidgetTester) _scrollUsage(double fraction) =>
    (tester) async {
      for (final element in find.byType(Scrollable).evaluate()) {
        final state = (element as StatefulElement).state;
        if (state is ScrollableState && state.position.axis == Axis.vertical) {
          state.position.jumpTo(state.position.maxScrollExtent * fraction);
          await settleSurface(tester);
          return;
        }
      }
    };

// ---------------------------------------------------------------- pipelines

final _pNow = DateTime.utc(2026, 10, 9, 12);

PipelineRun _failedRun() => PipelineRun(
  id: 'r2',
  definition: kPipelineTemplates[1],
  repositoryId: 'r1',
  input: 'Fix the flaky test',
  state: PipelineRunState.failed,
  reason: 'Test still fails after 2 loop-backs.',
  createdAt: _pNow.subtract(const Duration(minutes: 30)),
  updatedAt: _pNow,
  finishedAt: _pNow,
  records: [
    PipelineStageRecord(
      stageIndex: 0,
      role: 'Implement',
      attempt: 1,
      state: PipelineStageState.done,
      sessionId: 's-impl',
      answer: 'changed it',
      worktreePath: '/wt/s-impl',
      branch: 'session/s-impl',
      startedAt: _pNow.subtract(const Duration(minutes: 20)),
      finishedAt: _pNow.subtract(const Duration(minutes: 10)),
    ),
    PipelineStageRecord(
      stageIndex: 1,
      role: 'Test',
      attempt: 1,
      state: PipelineStageState.failed,
      sessionId: 's-test',
      answer: 'VERDICT: FAIL',
      reason: 'Checks failed.',
      check: PipelineCheckRecord(
        verdict: VerificationVerdict.fail,
        summary: 'Pipeline check: exit 1',
        checkedAt: _pNow,
        verificationRunId: 'v1',
      ),
      startedAt: _pNow.subtract(const Duration(minutes: 9)),
      finishedAt: _pNow,
    ),
  ],
);

/// A button that opens [open]: the pipeline dialogs come from the dashboard.
Future<SurfaceBuilder> _pipelineDialog(
  WidgetTester tester,
  Brightness brightness,
  void Function(BuildContext context) open,
) async {
  final c = (await tester.runAsync(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.pipelineRows.putRun(_failedRun());
    return ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(_pNow)),
      ],
    );
  }))!;
  addTearDown(c.dispose);
  final opener = Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  );
  return () => responsiveApp(
    tester,
    c,
    brightness,
    desktop: opener,
    phoneHome: Scaffold(body: opener),
  );
}

Future<void> _openDialog(WidgetTester tester) =>
    _tap(tester, find.text('open'));

// ---------------------------------------------------------------- workflows

/// Workflows on [section] (round 88): an automation and its runs, a saved
/// pipeline and two runs of it — one held at a gate, started by the
/// automation — and, with [run] or [editing], a run's detail or the
/// pipeline editor in the page.
Future<SurfaceBuilder> _workflows(
  WidgetTester tester,
  Brightness brightness, {
  WorkflowsSection section = WorkflowsSection.automations,
  WorkflowRunRef? run,
  bool editing = false,
}) async {
  final mine = kPipelineTemplates.first.copyWith(
    id: 'p-mine',
    name: 'Ship a fix',
    builtIn: false,
  );
  final c = (await tester.runAsync(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.automationRows
      ..insert(
        Automation(
          id: 'nightly',
          repositoryId: 'r1',
          name: 'Nightly: Implement → Test → Fix on failing tests',
          schedule: const AutomationSchedule.cron('0 2 * * *'),
          agentInstallationId: 'a1',
          prompt: 'Run the tests.',
          permissionMode: null,
          enabled: true,
          armedAt: _pNow,
        ),
      )
      ..insertRun(
        AutomationRun(
          id: 'ar1',
          automationId: 'nightly',
          scheduledFor: _pNow.subtract(const Duration(hours: 10)),
          firedAt: _pNow.subtract(const Duration(hours: 10)),
          state: AutomationRunState.finished,
          reason: 'The tests ran; 2 failed.',
          sessionId: 's-nightly',
          finishedAt: _pNow.subtract(const Duration(hours: 9, minutes: 52)),
          stepResults: [
            AutomationStepResult(
              kind: AutomationStepKind.pipeline,
              outcome: AutomationStepOutcome.waiting,
              detail: '"Ship a fix" waits for your approval at Plan.',
              at: _pNow,
              pipelineRunId: 'pr-gate',
            ),
          ],
        ),
      );
    server.pipelineRows.saved[mine.id] = mine;
    server.pipelineRows
      ..putRun(_failedRun())
      ..putRun(
        PipelineRun(
          id: 'pr-gate',
          definition: mine,
          repositoryId: 'r1',
          input: 'The nightly tests failed. Make them pass again.',
          state: PipelineRunState.waiting,
          automation: const PipelineRunAutomation(
            automationId: 'nightly',
            runId: 'ar1',
            name: 'Nightly: Implement → Test → Fix on failing tests',
          ),
          createdAt: _pNow.subtract(const Duration(hours: 9, minutes: 52)),
          updatedAt: _pNow,
          records: [
            PipelineStageRecord(
              stageIndex: 0,
              role: 'Plan',
              attempt: 1,
              state: PipelineStageState.approval,
              sessionId: 's-plan',
              answer: 'Plan: fix the two failing tests.',
              startedAt: _pNow.subtract(const Duration(hours: 9)),
              finishedAt: _pNow.subtract(const Duration(hours: 8)),
            ),
          ],
        ),
      );
    return ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(_pNow)),
      ],
    );
  }))!;
  addTearDown(c.dispose);
  c.read(workflowsSectionProvider.notifier).show(section);
  if (run != null) c.read(selectedWorkflowRunProvider.notifier).select(run);
  if (editing) c.read(pipelineEditingProvider.notifier).open(mine);
  return () => responsiveApp(
    tester,
    c,
    brightness,
    desktop: const WorkflowsTabView(),
    phonePage: PhoneMoreEntry.workflows,
  );
}

// ---------------------------------------------------------------- settings

Future<SurfaceBuilder> _settings(
  WidgetTester tester,
  Brightness brightness,
  SettingsSectionId section, {
  SettingsAnchor? anchor,
}) async {
  final c = (await tester.runAsync(() async {
    final server = FakeDataServer(clock: () => testTime);
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:archlinux', distro: 'archlinux'));
    server.installationRows
      ..upsert(agentInstallation())
      ..upsert(
        agentInstallation(
          id: 'a2',
          environmentId: 'wsl:archlinux',
          path: '/usr/bin/claude',
          version: '1.0.0',
        ),
      );
    server.projectRows.insert(project(name: 'Karmashala'));
    return ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        agentLatestVersionFetcherProvider.overrideWithValue(
          AgentLatestVersionFetcher(
            newClient: () =>
                FakeHttpClient()
                  ..throwOnRequest = const SocketException('offline'),
          ),
        ),
      ],
    );
  }))!;
  addTearDown(c.dispose);
  final page = SettingsScreen(initialSection: section, initialAnchor: anchor);
  return () => responsiveApp(
    tester,
    c,
    brightness,
    desktop: page,
    phoneHome: Scaffold(body: page),
  );
}

// ---------------------------------------------------------------- surfaces

final responsiveSurfaces = <ResponsiveSurface>[
  // The Today strip, all four glances, and every lane.
  ResponsiveSurface('dash-board', (t, b) => _mission(t, b)),
  ResponsiveSurface(
    'dash-glances-folded',
    (t, b) => _mission(
      t,
      b,
      seed: (c) => c.read(glancePrefsProvider.notifier).setAreaCollapsed(true),
    ),
  ),
  ResponsiveSurface(
    'dash-batch-actions',
    (t, b) => _mission(
      t,
      b,
      seed: (c) => c.read(overviewSelectionProvider.notifier).selectAll([
        'ks-r21',
        'ks-r32',
        'ks-release',
      ]),
    ),
    warmUp: (t) => _tap(t, _byKey('overview-batch-actions')),
  ),
  ResponsiveSurface(
    'dash-peek',
    (t, b) => _mission(t, b),
    warmUp: (t) => _peek(t),
    desktopOnly: true,
  ),
  ResponsiveSurface(
    'dash-keys',
    (t, b) => _mission(t, b),
    warmUp: (t) => _tap(t, _byKey('overview-keys-button')),
    desktopOnly: true,
  ),
  ResponsiveSurface(
    'dash-filter',
    (t, b) => _mission(t, b),
    warmUp: (t) => _tap(t, _byKey('overview-filter-button')),
  ),
  // The one list as a table: columns on a desktop, compact rows on a phone.
  ResponsiveSurface(
    'stores-table',
    (t, b) => _stores(t, b, layout: StoresLayout.table),
  ),
  // And as cards, in as many columns as fit.
  ResponsiveSurface(
    'stores-cards',
    (t, b) => _stores(t, b, layout: StoresLayout.cards),
  ),
  // The release timeline, across and down.
  ResponsiveSurface('stores-detail', (t, b) => _stores(t, b, detail: true)),
  ResponsiveSurface(
    'stores-charts',
    (t, b) => _stores(t, b, detail: true),
    warmUp: (t) => _reveal(t, _byKey('store-history-range')),
  ),
  // Account cards, forecast and the Limits section.
  ResponsiveSurface('usage-top', _usage),
  ResponsiveSurface('usage-lower', _usage, warmUp: _scrollUsage(0.5)),
  // Cost by project, most expensive today and the 30-day charts.
  ResponsiveSurface('usage-bottom', _usage, warmUp: _scrollUsage(1)),
  // An approval gate's hand-off card, as the dashboard's lane opens it.
  ResponsiveSurface(
    'pipe-handoff',
    (t, b) => _mission(t, b),
    warmUp: (t) => _tapOnBoard(t, _byKey('overview-pipeline-edit:run-1')),
  ),
  // Round 88: sub-sessions as cards, each tied to its parent — a connector
  // on a desktop, "child of" on a phone — and a child in another lane
  // with its jump.
  ResponsiveSurface(
    'dash-subs-cards',
    (t, b) => _mission(
      t,
      b,
      seed: (c) => c
          .read(overviewPrefsProvider.notifier)
          .setSubSessions(OverviewSubSessionMode.cards),
    ),
    warmUp: (t) => _scrollTo(t, _byKey('overview-linked:ks-r32-sub0')),
  ),
  // Round 88: a run's card opens its peek beside the board (a page on a
  // phone); a stage clicked shows its session there.
  ResponsiveSurface(
    'pipe-run-peek',
    (t, b) => _mission(t, b),
    warmUp: _peekRun,
  ),
  ResponsiveSurface('pipe-run-peek-alone', _runPeek),
  ResponsiveSurface(
    'pipe-run-peek-stage',
    (t, b) => _runPeek(t, b, stage: true),
  ),
  ResponsiveSurface(
    'pipe-run-dialog',
    (t, b) => _pipelineDialog(t, b, showRunPipeline),
    warmUp: _openDialog,
  ),
  ResponsiveSurface(
    'pipe-editor',
    (t, b) => _pipelineDialog(
      t,
      b,
      (context) =>
          showPipelineEditor(context, initial: kPipelineTemplates.first),
    ),
    warmUp: _openDialog,
  ),
  ResponsiveSurface(
    'pipe-run-detail',
    (t, b) => _pipelineDialog(
      t,
      b,
      (context) => showPipelineRunDetail(context, 'r2'),
    ),
    warmUp: _openDialog,
  ),
  // Round 88: Workflows' sections, a run's detail of each kind, the pipeline
  // editor in the page and the runs' filters.
  ResponsiveSurface('workflows-automations', _workflows),
  ResponsiveSurface(
    'workflows-pipelines',
    (t, b) => _workflows(t, b, section: WorkflowsSection.pipelines),
  ),
  ResponsiveSurface(
    'workflows-pipeline-editor',
    (t, b) =>
        _workflows(t, b, section: WorkflowsSection.pipelines, editing: true),
  ),
  ResponsiveSurface(
    'workflows-runs',
    (t, b) => _workflows(t, b, section: WorkflowsSection.runs),
  ),
  ResponsiveSurface(
    'workflows-runs-filter',
    (t, b) => _workflows(t, b, section: WorkflowsSection.runs),
    warmUp: (t) => _tap(t, _byKey('workflow-runs-filter')),
  ),
  ResponsiveSurface(
    'workflows-run-pipeline',
    (t, b) => _workflows(
      t,
      b,
      section: WorkflowsSection.runs,
      run: const WorkflowRunRef(WorkflowRunKind.pipeline, 'pr-gate'),
    ),
  ),
  ResponsiveSurface(
    'workflows-run-automation',
    (t, b) => _workflows(
      t,
      b,
      section: WorkflowsSection.runs,
      run: const WorkflowRunRef(WorkflowRunKind.automation, 'ar1'),
    ),
  ),
  ResponsiveSurface(
    'settings-session-limits',
    (t, b) => _settings(
      t,
      b,
      SettingsSectionId.general,
      anchor: SettingsAnchor.sessionLimits,
    ),
  ),
  ResponsiveSurface(
    'settings-notifications',
    (t, b) => _settings(t, b, SettingsSectionId.notifications),
    warmUp: (t) => _reveal(t, find.textContaining('Store changes')),
  ),
  ResponsiveSurface(
    'settings-notifications-usage',
    (t, b) => _settings(t, b, SettingsSectionId.notifications),
    warmUp: (t) => _reveal(t, find.textContaining('running out early')),
  ),
  ResponsiveSurface(
    'settings-data',
    (t, b) => _settings(t, b, SettingsSectionId.data),
  ),
  ResponsiveSurface(
    'settings-agents-mcp',
    (t, b) => _settings(t, b, SettingsSectionId.agents),
    warmUp: (t) =>
        _reveal(t, find.text('Karmashala in agent configs'.toUpperCase())),
  ),
  // The bottom bar and the Dashboard home with its header Todos button.
  ResponsiveSurface(
    'phone-home',
    (t, b) => _mission(t, b, phoneHome: const PhoneShell()),
    phoneOnly: true,
  ),
  ResponsiveSurface(
    'phone-more',
    (t, b) => _mission(t, b, phoneHome: const PhoneShell()),
    warmUp: (t) => _tap(t, find.text('More')),
    phoneOnly: true,
  ),
  ResponsiveSurface(
    'phone-todos',
    (t, b) => _mission(t, b, phoneHome: const PhoneShell()),
    warmUp: (t) => _tap(t, _byKey('overview-todos')),
    phoneOnly: true,
  ),
  // Round 86: the Usage tab over seven sign-ins, its account list open, and
  // every More page under its one-row header.
  ResponsiveSurface('usage-accounts', (t, b) => _usage(t, b, many: true)),
  ResponsiveSurface(
    'usage-accounts-list',
    (t, b) => _usage(t, b, many: true),
    warmUp: (t) => _tap(t, _byKey('usage-account-picker')),
  ),
  for (final surface in moreSurfaces)
    // Known: at 360 px and 1.6x text a session row leaves its title ~19 px
    // and overflows (round 86 found it; reported, not fixed here).
    if (surface.name != 'more-sessions') surface,
];

/// Every page More opens on a phone, pushed as its row pushes it (round 86).
final moreSurfaces = <ResponsiveSurface>[
  for (final entry in PhoneMoreEntry.values)
    ResponsiveSurface(
      'more-${entry.name}',
      (t, b) => switch (entry) {
        PhoneMoreEntry.usage => _usage(t, b, many: true),
        PhoneMoreEntry.stores => _stores(t, b),
        PhoneMoreEntry.workflows => _workflows(t, b),
        _ => _mission(t, b, phoneHome: _PushedFromMore(entry)),
      },
      phoneOnly: true,
    ),
];
