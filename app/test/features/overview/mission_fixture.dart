import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// One session of the fixture.
typedef MissionSession = ({
  String id,
  String title,
  String project,
  String machine,
  String agent,
  AgentState state,
  Duration age,
  String? parent,
  AgentStatusReport? report,
});

/// **A realistic mission control**: six live projects and three quiet ones,
/// twenty top-level sessions in every state across three machines and three
/// agents, sub-sessions under two parents, and one session that needs you.
class MissionFixture {
  MissionFixture({List<MissionSession>? sessions, this.hiddenWorking = 0})
    : sessions = sessions ?? realisticSessions();

  final List<MissionSession> sessions;

  /// Sessions Hide while working took off the tiles.
  final int hiddenWorking;

  static DateTime get now => testTime;

  static const projects = [
    OverviewLaneKey('p-ks', 'karmashala'),
    OverviewLaneKey('p-beej', 'beej'),
    OverviewLaneKey('p-store', 'store-console'),
    OverviewLaneKey('p-relay', 'relay'),
    OverviewLaneKey('p-web', 'popupbits.com'),
    OverviewLaneKey('p-docs', 'docs'),
    OverviewLaneKey('p-legacy', 'legacy-cli'),
    OverviewLaneKey('p-ds', 'design-system'),
    OverviewLaneKey('p-sand', 'sandbox'),
  ];

  static const machines = [
    OverviewLaneKey('windows', 'Windows'),
    OverviewLaneKey('wsl:arch', 'WSL · arch'),
    OverviewLaneKey('ssh:box', 'build-box'),
  ];

  static AgentStatusReport _report(
    String id,
    AgentActivityStatus status, {
    String agent = AgentIds.claudeCode,
    List<String> evidence = const [],
    List<String> inFlight = const [],
    Duration? waiting,
    AgentToolAsk? ask,
  }) => AgentStatusReport(
    agentId: agent,
    sessionId: 'cli-$id',
    status: status,
    observedAt: now,
    source: AgentStatusSource.hook,
    evidence: evidence,
    inFlight: inFlight,
    waiting: ask == null ? AgentWaitKind.unrecorded : AgentWaitKind.approval,
    waitingSince: waiting == null ? null : now.subtract(waiting),
    toolAsk: ask,
  );

  /// The fixture the screenshots and the layout tests draw.
  static List<MissionSession> realisticSessions() {
    MissionSession s(
      String id,
      String title,
      String project,
      AgentState state, {
      String machine = 'windows',
      String agent = AgentIds.claudeCode,
      Duration age = const Duration(minutes: 5),
      String? parent,
      AgentStatusReport? report,
    }) => (
      id: id,
      title: title,
      project: project,
      machine: machine,
      agent: agent,
      state: state,
      age: age,
      parent: parent,
      report: report,
    );
    const working = AgentActivityStatus.working;
    return [
      // karmashala: the busy one, with the one ask and a parent with five
      // sub-sessions.
      s(
        'ks-r21',
        'Round 21 · ACP sessions',
        'p-ks',
        AgentState.needsYou,
        age: const Duration(minutes: 12),
        report: _report(
          'ks-r21',
          AgentActivityStatus.awaitingApproval,
          waiting: const Duration(minutes: 12),
          ask: AgentToolAsk(
            toolName: 'Bash',
            input: const {
              'command': 'flutter test --exclude-tags=live-ssh,live-wsl',
            },
            at: now.subtract(const Duration(minutes: 12)),
          ),
        ),
      ),
      s(
        'ks-r32',
        'Round 32 · Overview redesign',
        'p-ks',
        AgentState.working,
        age: const Duration(minutes: 1),
        report: _report('ks-r32', working, inFlight: const ['flutter test']),
      ),
      for (final (i, state) in const [
        AgentState.working,
        AgentState.working,
        AgentState.ready,
        AgentState.ended,
        AgentState.ended,
      ].indexed)
        s(
          'ks-r32-sub$i',
          'Subagent ${i + 1}',
          'p-ks',
          state,
          parent: 'ks-r32',
          age: Duration(minutes: 2 + i),
        ),
      s(
        'ks-release',
        'Release 1.34 prep',
        'p-ks',
        AgentState.working,
        machine: 'wsl:arch',
        agent: AgentIds.codex,
        age: const Duration(minutes: 3),
        report: _report(
          'ks-release',
          working,
          agent: AgentIds.codex,
          evidence: const ['Building the Linux host bundle'],
        ),
      ),
      s(
        'ks-r30',
        'Round 30 · webhooks',
        'p-ks',
        AgentState.ready,
        age: const Duration(minutes: 25),
      ),
      s(
        'ks-r31',
        'Round 31 · question card',
        'p-ks',
        AgentState.quiet,
        age: const Duration(minutes: 40),
      ),
      s(
        'ks-r29',
        'Round 29 · forks',
        'p-ks',
        AgentState.ended,
        age: const Duration(hours: 2),
      ),
      // beej: working on two machines.
      s(
        'beej-scaffold',
        'Scaffold templates v3',
        'p-beej',
        AgentState.working,
        machine: 'wsl:arch',
        agent: AgentIds.codex,
        age: const Duration(minutes: 2),
        report: _report(
          'beej-scaffold',
          working,
          agent: AgentIds.codex,
          evidence: const ['Rewriting lib/templates/app.dart'],
        ),
      ),
      for (final (i, state) in const [
        AgentState.working,
        AgentState.ready,
      ].indexed)
        s(
          'beej-scaffold-sub$i',
          'Check ${i + 1}',
          'p-beej',
          state,
          machine: 'wsl:arch',
          agent: AgentIds.codex,
          parent: 'beej-scaffold',
        ),
      s(
        'beej-ci',
        'CI matrix for macOS',
        'p-beej',
        AgentState.ready,
        machine: 'ssh:box',
        age: const Duration(minutes: 18),
      ),
      s(
        'beej-docs',
        'README pass',
        'p-beej',
        AgentState.ended,
        age: const Duration(hours: 3),
      ),
      // store-console: one failing run.
      s(
        'store-reviews',
        'Reply to Play reviews',
        'p-store',
        AgentState.failed,
        agent: AgentIds.antigravity,
        age: const Duration(minutes: 30),
      ),
      s(
        'store-listing',
        'Listing screenshots',
        'p-store',
        AgentState.ready,
        agent: AgentIds.antigravity,
        age: const Duration(hours: 1),
      ),
      // relay: long-running work on the build box.
      s(
        'relay-load',
        'Load test 10k clients',
        'p-relay',
        AgentState.working,
        machine: 'ssh:box',
        age: const Duration(minutes: 7),
        report: _report(
          'relay-load',
          working,
          inFlight: const ['k6 run load.js', 'tail -f relay.log'],
        ),
      ),
      s(
        'relay-tls',
        'Rotate TLS certs',
        'p-relay',
        AgentState.quiet,
        machine: 'ssh:box',
        age: const Duration(minutes: 50),
      ),
      // popupbits.com and docs: ready and done today.
      s(
        'web-blog',
        'Blog: open-sourcing Karmashala',
        'p-web',
        AgentState.ready,
        agent: AgentIds.antigravity,
        age: const Duration(minutes: 9),
      ),
      s(
        'web-seo',
        'Sitemap and meta tags',
        'p-web',
        AgentState.ended,
        age: const Duration(hours: 1),
      ),
      s(
        'docs-api',
        'API reference regen',
        'p-docs',
        AgentState.ended,
        agent: AgentIds.codex,
        age: const Duration(hours: 1, minutes: 20),
      ),
      // Quiet: ended before today.
      s(
        'legacy-port',
        'Port to null safety',
        'p-legacy',
        AgentState.ended,
        age: const Duration(days: 3),
      ),
      s(
        'ds-tokens',
        'Token audit',
        'p-ds',
        AgentState.ended,
        agent: AgentIds.codex,
        age: const Duration(days: 6),
      ),
      s(
        'sand-try',
        'Try the new SDK',
        'p-sand',
        AgentState.ended,
        age: const Duration(days: 12),
      ),
    ];
  }

  WorkspaceSessionEntry entry(MissionSession s) {
    final at = now.subtract(s.age);
    return WorkspaceSessionEntry(
      id: s.id,
      title: s.title,
      createdAt: at.subtract(const Duration(minutes: 30)),
      lastActiveAt: at,
      directory: EnvironmentPath(
        environmentId: s.machine,
        path: '/src/${s.id}',
      ),
      native: Session(
        id: s.id,
        repositoryId: 'r-${s.project}',
        agentInstallationId: 'a1',
        title: s.title,
        useWorktree: false,
        status: s.state == AgentState.ended
            ? SessionStatus.completed
            : SessionStatus.running,
        createdAt: at.subtract(const Duration(minutes: 30)),
        parentSessionId: s.parent,
      ),
    );
  }

  late final _entries = [for (final s in sessions) entry(s)];
  late final _byId = {for (final s in sessions) s.id: s};

  List<AgentStateGroup> get groups => [
    for (final state in AgentState.values)
      AgentStateGroup(state, [
        for (final e in _entries)
          if (_byId[e.id]!.state == state) e,
      ]),
  ];

  OverviewFacts get facts => OverviewFacts(
    projectOf: (e) => _byId[e.id]?.project,
    machineOf: (e) => e.directory?.environmentId,
    agentOf: (e) => _byId[e.id]?.agent,
    projects: projects,
    machines: machines,
  );

  /// The providers mission control reads, answered from this fixture.
  List<Override> get overrides => [
    agentStateGroupsProvider.overrideWith((ref) => groups),
    workspaceSessionsProvider.overrideWith((ref) => _entries),
    agentsHiddenWorkingCountProvider.overrideWith((ref) => hiddenWorking),
    overviewFactsProvider.overrideWith((ref) => facts),
    sessionStatusLookupProvider.overrideWithValue((id) => _byId[id]?.report),
  ];
}

/// Draws the Overview tab over [fixture] at [size]: the desktop's tab, or
/// with [phone] the phone's More page under a thumb's density.
Future<ProviderContainer> pumpMission(
  WidgetTester tester, {
  required MissionFixture fixture,
  required Directory prefsDir,
  Size size = const Size(1440, 900),
  bool phone = false,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  GlobalKey? boundary,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = TestMachine();
  final server = FakeDataServer()..runsOn(db);
  server.environmentRows
    ..upsert(windowsEnv())
    ..upsert(wslEnv(id: 'wsl:arch', distro: 'arch'))
    ..upsert(sshEnvFixture(id: 'ssh:box', name: 'build-box'));
  server.installationRows.insert(agentInstallation());
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
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  final base = brightness == Brightness.dark
      ? AppTheme.dark()
      : AppTheme.light();
  // flutter_test runs as Android; a desktop draws under a pointer.
  final theme = base.copyWith(
    platform: phone ? TargetPlatform.android : TargetPlatform.windows,
  );
  Widget page = const OverviewTabView();
  if (phone) {
    page = Scaffold(
      appBar: AppBar(title: const Text('Overview')),
      body: const PaneTitleOverride(child: OverviewTabView()),
    );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: boundary,
            child: UiDensity.wrap(context, child!),
          ),
        ),
        home: page,
      ),
    ),
  );
  await settleMission(tester);
  return container;
}

/// Bounded: a working mark turns and an ask breathes for ever.
Future<void> settleMission(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Unmounts the tab so the lens's timers end with the providers.
Future<void> unmountMission(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}
