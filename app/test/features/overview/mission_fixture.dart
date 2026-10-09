import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_verification/verification.dart'
    show CodeFreshness, VerificationRun;
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala/src/features/overview/presentation/overview_tab_view.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala_git/git.dart' show FileDiffStat;
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala_session/delivery.dart'
    show OfferedAction, SessionDelivery;
import 'package:karmashala/src/features/sessions/application/session_active_model_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ActiveModelSource, ActivityEntry, ActivityKind;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart' show PhoneTabsScope;
import 'package:karmashala_ui/rows.dart' show SessionDiffStat;
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
  MissionFixture({
    List<MissionSession>? sessions,
    this.hiddenWorking = 0,
    this.answers = const {},
    this.glances = const {},
    this.files = const {},
    this.stats = const {},
    this.panes = const {},
    this.fileStats = const {},
    this.models = const {},
    this.merges = const {},
    this.peekChat,
    this.activity = const [],
    this.contexts = const [],
    this.contextOfProject = const {},
    this.starting = const {},
    this.verificationRuns = const [],
    this.codeFreshness = const {},
  }) : sessions = sessions ?? realisticSessions();

  /// Verification runs the server holds, and what each recorded commit's
  /// freshness reads as now.
  final List<VerificationRun> verificationRuns;
  final Map<String?, CodeFreshness> codeFreshness;

  /// Sessions whose row is still `created`: started, with nothing reported.
  final Set<String> starting;

  /// The contexts the owner created, and which project each one holds.
  final List<OverviewLaneKey> contexts;
  final Map<String, String> contextOfProject;

  /// Each session's changed files.
  final Map<String, List<String>> files;

  /// Each session's diff against its base, as git would count it.
  final Map<String, SessionDiffStat> stats;

  /// The terminal pane each terminal-hosted session has on this machine.
  final Map<String, String> panes;

  /// Lines added and removed per file, by checkout path.
  final Map<String, Map<String, FileDiffStat>> fileStats;

  /// The model each session's agent says it runs, by label.
  final Map<String, String> models;

  /// The Merge the delivery strip offers each session, and the base it
  /// would merge into.
  final Map<String, (OfferedAction, String)> merges;

  /// What the peek draws for a session's chat; a line naming it by default.
  final Widget Function(WorkspaceSessionEntry entry, DateTime? seenUntil)?
  peekChat;

  /// The server's activity log, which the strips and the heartbeat draw.
  final List<ActivityEntry> activity;

  /// Each session's last answer, as the reader would find it.
  final Map<String, LastAnswer> answers;

  /// Each session's plan and open calls, as one server read would say.
  final Map<String, OverviewGlance> glances;

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
        report: _report('ks-r32', working, inFlight: const [rawScript]),
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

  /// A raw script, as a hook names a background shell by its command.
  static const rawScript =
      r'$sp = "$env:TEMP\scratch"; Set-Location $root; '
      r'flutter test > "$sp\app.txt" 2>&1; "exit=$LASTEXITCODE"';

  /// The last two hours of the activity log for [realisticSessions]: turns,
  /// waits, and what is still running now.
  static List<ActivityEntry> realisticActivity() {
    var id = 0;
    final out = <ActivityEntry>[];
    void at(String session, ActivityKind kind, int minutesAgo) => out.add(
      ActivityEntry(
        id: ++id,
        at: now.subtract(Duration(minutes: minutesAgo)),
        kind: kind,
        sessionId: session,
        source: 'fixture',
      ),
    );
    void turn(String session, int from, [int? to]) {
      at(session, ActivityKind.turnStarted, from);
      if (to != null) at(session, ActivityKind.turnEnded, to);
    }

    void wait(String session, int from, [int? to]) {
      at(session, ActivityKind.waitBegan, from);
      if (to != null) at(session, ActivityKind.waitEnded, to);
    }

    for (final (session, started) in const [
      ('ks-r21', 95),
      ('ks-r32', 110),
      ('ks-release', 50),
      ('ks-r30', 75),
      ('ks-r31', 85),
      ('beej-scaffold', 130),
      ('beej-ci', 55),
      ('store-reviews', 80),
      ('store-listing', 115),
      ('relay-load', 52),
      ('relay-tls', 65),
      ('web-blog', 35),
    ]) {
      at(session, ActivityKind.sessionStarted, started);
    }
    turn('ks-r21', 90, 40);
    turn('ks-r21', 30);
    wait('ks-r21', 12);
    turn('ks-r32', 105, 72);
    turn('ks-r32', 64);
    turn('ks-release', 45);
    turn('ks-r30', 70, 25);
    turn('ks-r31', 40);
    turn('beej-scaffold', 125, 92);
    wait('beej-scaffold', 92, 84);
    turn('beej-scaffold', 84);
    turn('beej-ci', 50, 18);
    turn('store-reviews', 75, 30);
    turn('store-listing', 110, 60);
    turn('relay-load', 50);
    turn('relay-tls', 60, 50);
    turn('web-blog', 30, 9);
    return out;
  }

  /// What one server read says some of [realisticSessions] are doing.
  static Map<String, OverviewGlance> realisticGlances() => {
    'ks-r32': OverviewGlance(
      plan: const AgentPlan(
        items: [
          AgentPlanItem(
            text: 'Map the Overview',
            state: AgentPlanItemState.completed,
          ),
          AgentPlanItem(
            text: 'Fix the last answer',
            state: AgentPlanItemState.completed,
          ),
          AgentPlanItem(
            text: 'Write the layout tests',
            state: AgentPlanItemState.inProgress,
          ),
          AgentPlanItem(
            text: 'Check it in a probe',
            state: AgentPlanItemState.pending,
          ),
        ],
      ),
      open: [
        OverviewOpenCall(
          phrase: 'Run the overview tests',
          raw: rawScript,
          since: now.subtract(const Duration(minutes: 4)),
          background: true,
        ),
      ],
    ),
    'ks-release': OverviewGlance(
      open: [
        OverviewOpenCall(
          phrase: 'Editing CHANGELOG.md',
          since: now.subtract(const Duration(minutes: 1)),
        ),
      ],
    ),
    'beej-scaffold': const OverviewGlance(
      plan: AgentPlan(
        items: [
          AgentPlanItem(
            text: 'Port the app template',
            state: AgentPlanItemState.completed,
          ),
          AgentPlanItem(
            text: 'Port the router template',
            state: AgentPlanItemState.inProgress,
          ),
          AgentPlanItem(
            text: 'Run the golden tests',
            state: AgentPlanItemState.pending,
          ),
        ],
      ),
    ),
    'ks-r21': const OverviewGlance(
      plan: AgentPlan(
        items: [
          AgentPlanItem(
            text: 'Wire the ACP client',
            state: AgentPlanItemState.completed,
          ),
          AgentPlanItem(
            text: 'Run the suite',
            state: AgentPlanItemState.inProgress,
          ),
        ],
      ),
    ),
  };

  /// The last answers of some of [realisticSessions].
  static Map<String, LastAnswer> realisticAnswers() => {
    'ks-r30': const LastAnswer.of(
      'Webhooks are wired: **3 events** reach the inbox, and the retry '
      'backs off to five minutes. The tests are in `webhooks_test.dart`.',
    ),
    'beej-ci': const LastAnswer.of(
      'The macOS matrix is green on **Xcode 16.4**; the beta job is '
      'allowed to fail.',
    ),
    'web-blog': const LastAnswer.of(
      'Drafted the post. It needs a hero image and your read of the '
      'licensing paragraph.',
    ),
    'store-listing': const LastAnswer.of('Framed **8 screenshots**.'),
  };

  /// The files some of [realisticSessions] changed.
  static Map<String, List<String>> realisticFiles() => {
    'ks-r32': [
      'app/lib/src/features/overview/presentation/overview_hybrid.dart',
      'app/lib/src/features/overview/presentation/overview_cards.dart',
      'app/test/features/overview/overview_hybrid_test.dart',
    ],
    'ks-release': ['CHANGELOG.md', 'app/pubspec.yaml'],
    'beej-scaffold': [
      for (var i = 1; i <= 9; i++) 'lib/templates/part_$i.dart',
    ],
    'ks-r30': ['server/lib/src/webhooks.dart'],
  };

  /// Diff sizes for some of [realisticSessions].
  static Map<String, SessionDiffStat> realisticStats() => const {
    'ks-r32': SessionDiffStat(added: 620, removed: 40, changedFiles: 3),
    'ks-r30': SessionDiffStat(added: 310, removed: 0, changedFiles: 2),
  };

  /// [MissionFixture] with every reading above filled in.
  static MissionFixture full({
    Widget Function(WorkspaceSessionEntry entry, DateTime? seenUntil)? peekChat,
    List<VerificationRun> verificationRuns = const [],
    Map<String?, CodeFreshness> codeFreshness = const {},
  }) => MissionFixture(
    peekChat: peekChat,
    verificationRuns: verificationRuns,
    codeFreshness: codeFreshness,
    models: const {'ks-r32': 'Opus 5.5'},
    stats: realisticStats(),
    fileStats: const {
      '/src/ks-r32': {
        'app/lib/src/features/overview/presentation/overview_hybrid.dart':
            FileDiffStat(added: 212, removed: 40),
        'app/lib/src/features/overview/presentation/overview_cards.dart':
            FileDiffStat(added: 168, removed: 0),
      },
    },
    answers: realisticAnswers(),
    glances: realisticGlances(),
    files: realisticFiles(),
    activity: realisticActivity(),
  );

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
        status: starting.contains(s.id)
            ? SessionStatus.created
            : s.state == AgentState.ended
            ? SessionStatus.completed
            : SessionStatus.running,
        createdAt: at.subtract(const Duration(minutes: 30)),
        parentSessionId: s.parent,
      ),
    );
  }

  /// The reads the Overview makes; its answers can be changed mid-test.
  late final reader = FakeOverviewReader(
    answers: {...answers},
    glances: glances,
    files: files,
  );

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
    contextOf: (e) => contextOfProject[_byId[e.id]?.project],
    projects: projects,
    machines: machines,
    contexts: contexts,
  );

  /// The providers mission control reads, answered from this fixture.
  List<Override> get overrides => [
    agentStateGroupsProvider.overrideWith((ref) => groups),
    workspaceSessionsProvider.overrideWith((ref) => _entries),
    agentsHiddenWorkingCountProvider.overrideWith((ref) => hiddenWorking),
    overviewFactsProvider.overrideWith((ref) => facts),
    sessionStatusLookupProvider.overrideWithValue((id) => _byId[id]?.report),
    agentSessionStatusProvider.overrideWith(
      (ref, id) => switch (_byId[id]?.report) {
        final report? => Stream.value(report),
        null => const Stream<AgentStatusReport>.empty(),
      },
    ),
    overviewPeekChatProvider.overrideWithValue(
      peekChat ??
          (entry, seenUntil) => Text(
            'chat:${entry.id} seen:${seenUntil?.toIso8601String()}',
            key: ValueKey('overview-peek-chat:${entry.id}'),
          ),
    ),
    overviewSessionPaneProvider.overrideWith((ref, id) => panes[id]),
    sessionDeliveryActionsProvider.overrideWith((ref, id) => [?merges[id]?.$1]),
    sessionDeliveryProvider.overrideWith(
      (ref, id) async => SessionDelivery(baseBranch: merges[id]?.$2),
    ),
    sessionActiveModelProvider.overrideWith(
      (ref, id) => switch (models[id]) {
        final label? => SessionActiveModel(
          modelId: label,
          label: label,
          observedAt: now,
          source: ActiveModelSource.agent,
        ),
        null => null,
      },
    ),
    overviewFileStatsProvider.overrideWith(
      (ref, checkout) async => fileStats[checkout.path] ?? const {},
    ),
    sessionDiffStatProvider.overrideWith(
      (ref, id) async => stats[id] ?? SessionDiffStat.unknown,
    ),
    overviewReaderProvider.overrideWithValue(reader),
  ];
}

/// The Overview's reads, answered from a fixture: nothing reaches a server.
class FakeOverviewReader implements OverviewReader {
  FakeOverviewReader({
    this.answers = const {},
    this.glances = const {},
    this.files = const {},
  });

  final Map<String, LastAnswer> answers;
  final Map<String, OverviewGlance> glances;
  final Map<String, List<String>> files;
  final asked = <String>[];

  @override
  Future<LastAnswer> lastAnswer(String sessionId) async {
    asked.add(sessionId);
    return answers[sessionId] ?? LastAnswer.none;
  }

  @override
  Future<OverviewGlance?> glance(String sessionId) async => glances[sessionId];

  @override
  Future<List<String>?> changedFiles(String sessionId) async =>
      files[sessionId];
}

/// Draws the Overview tab over [fixture] at [size]: the desktop's tab, or
/// with [phone] the phone's Dashboard tab under a thumb's density.
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
  Widget? home,
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
  server.activity.addAll(fixture.activity);
  fixture.verificationRuns.forEach(server.verificationRows.put);
  server.gitWork.codeFreshness.addAll(fixture.codeFreshness);
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
  Widget page = home ?? const OverviewTabView();
  if (phone && home == null) {
    // The phone's Dashboard tab, as the phone shell mounts it.
    page = const Scaffold(
      body: PhoneTabsScope(child: PaneTitleOverride(child: OverviewTabView())),
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

/// The Overview's own list, for a scroll that must not pick a text field's.
final Finder hybridList = find
    .descendant(
      of: find.byKey(const ValueKey('overview-hybrid')),
      matching: find.byType(Scrollable),
    )
    .first;
