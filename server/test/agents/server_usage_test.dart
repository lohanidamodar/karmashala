import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/forwarded_runs.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_host/src/agents/server_usage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'agent_work_support.dart';

/// **Usage, read by the server** (slice 2a): through the one throttled
/// service, recorded in the history and told as a state only when the state
/// moved; failures become a state that keeps the last reading; a session
/// moving asks again. The vendor is scripted — no request leaves the test.
void main() {
  final start = DateTime.utc(2026, 9, 26, 12);
  const account = 'claudeCode@$localHostEnvironmentId';

  late MutableClock clock;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late ScriptedUsageService vendor;
  late ServerAgentWork work;

  AgentUsage reading(double percent) => AgentUsage(
    fetchedAt: clock.nowUtc(),
    email: 'me@example.com',
    windows: [
      UsageWindow(
        label: '5-h',
        percent: percent,
        span: kUsageFiveHourWindow,
        resetsAt: start.add(const Duration(hours: 4)),
      ),
    ],
  );

  AgentInstallation installation(
    String id,
    String agentId, {
    String path = '/usr/local/bin/agent',
  }) => AgentInstallation(
    id: id,
    agentId: agentId,
    executable: EnvironmentPath(
      environmentId: localHostEnvironmentId,
      path: path,
    ),
    createdAt: start,
  );

  void record(List<AgentInstallation> rows) => service.reconcileProbe(
    environmentId: localHostEnvironmentId,
    readAt: clock.nowUtc(),
    found: rows,
    probed: const {},
    readings: const {},
  );

  List<DataChange> toldChanges() => [for (final b in told) ...b.changes];

  setUp(() {
    clock = MutableClock(start);
    db = AppDatabase.memory();
    service = DataService(db, clock: () => clock.now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    service.ensureEnvironment(localHostEnvironment(start));
    record([installation('claude1', AgentIds.claudeCode)]);
    vendor = ScriptedUsageService(clock: clock, answer: (_) => reading(20));
    work = ServerAgentWork(
      data: service,
      runs: ForwardedRuns(),
      clock: clock,
      ids: CountingIds(),
      usageService: (_) => vendor,
      claudeAuth: ClaudeAuthService(
        ids: CountingIds('claude'),
        clock: clock,
        readKeychain: () async => const ClaudeKeychainRead.notFound(),
      ),
      onItsOwn: false,
    )..attach();
    told.clear();
  });

  tearDown(() {
    work.stop();
    db.close();
  });

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  test('a refresh reads, records the history and tells the state', () async {
    final reply = await app.handleLater(const UsageRefresh());
    expect(vendor.asked, hasLength(1));
    final state = reply.value.single;
    expect(state.accountKey, account);
    expect(state.agentId, AgentIds.claudeCode);
    expect(state.usage!.windows.single.percent, 20);
    expect(state.failure, isNull);
    // The floor of a five-hour window: three minutes.
    expect(state.nextAt, start.add(const Duration(minutes: 3)));

    final history = app.handle(UsageHistory(account, DateTime.utc(2000))).value;
    expect(history.single.percent, 20);
    expect(history.single.windowLabel, '5-h');

    expect(toldChanges().whereType<UsageRecorded>().single.accountKey, account);
    final stateTold = toldChanges().whereType<UsageStateChanged>().single;
    expect(stateTold.state.usage!.windows.single.percent, 20);
    // What was told is what `usage.current` answers.
    final current = await app.handleLater(const UsageCurrent());
    expect(current.value.single.sameAs(stateTold.state), isTrue);
  });

  test(
    'a server told to work only when asked reads nothing on its own',
    () async {
      // `KARMASHALA_AGENT_WORK=off` — a test's server — builds the work this
      // way: no usage schedule, no start-up check.
      await work.start();
      await pumpEventQueue();
      expect(vendor.asked, isEmpty);
      expect(toldChanges(), isEmpty);
    },
  );

  test('inside the floor a refresh asks nobody and tells nothing', () async {
    await app.handleLater(const UsageRefresh());
    final toldBefore = toldChanges().length;
    clock.advance(const Duration(minutes: 1));
    final again = await app.handleLater(
      const UsageRefresh(accountKey: account),
    );
    expect(vendor.asked, hasLength(1));
    expect(again.value.single.usage!.windows.single.percent, 20);
    expect(toldChanges(), hasLength(toldBefore));
  });

  test('a rate limit is a state with its wait, keeps the reading, and is '
      'sat out rather than pushed on', () async {
    await app.handleLater(const UsageRefresh());
    clock.advance(const Duration(minutes: 4));
    vendor.answer = (_) => throw UsageException(
      'Too many requests.',
      kind: UsageFailureKind.rateLimited,
      retryIn: const Duration(minutes: 2),
    );
    told.clear();

    final limited = (await app.handleLater(const UsageRefresh())).value.single;
    expect(vendor.asked, hasLength(2));
    expect(limited.failure!.kind, UsageFailureKind.rateLimited);
    final waitEnds = clock.nowUtc().add(const Duration(minutes: 2));
    expect(limited.failure!.until, waitEnds);
    expect(limited.nextAt, waitEnds);
    expect(
      limited.usage!.windows.single.percent,
      20,
      reason: 'the last reading stands, with its own age',
    );
    expect(
      toldChanges().whereType<UsageStateChanged>().single.state.failure!.kind,
      UsageFailureKind.rateLimited,
    );
    expect(toldChanges().whereType<UsageRecorded>(), isEmpty);

    clock.advance(const Duration(seconds: 30));
    final still = (await app.handleLater(const UsageRefresh())).value.single;
    expect(vendor.asked, hasLength(2), reason: 'a limit in force is sat out');
    expect(still.failure!.kind, UsageFailureKind.rateLimited);
  });

  test('a lapsed sign-in is a state asked again at the idle ceiling', () async {
    await app.handleLater(const UsageRefresh());
    clock.advance(const Duration(minutes: 4));
    vendor.answer = (_) =>
        throw UsageException('Sign in again.', kind: UsageFailureKind.auth);
    final state = (await app.handleLater(const UsageRefresh())).value.single;
    expect(state.failure!.kind, UsageFailureKind.auth);
    expect(state.failure!.message, 'Sign in again.');
    expect(state.failure!.until, isNull);
    expect(state.nextAt, clock.nowUtc().add(kUsageRetryAfterAuth));
    expect(state.usage!.windows.single.percent, 20);
  });

  test('a refresh of an account nobody has is refused notFound', () async {
    await expectLater(
      app.handleLater(const UsageRefresh(accountKey: 'codex@nowhere')),
      refused(DataRefusalCode.notFound, 'codex@nowhere'),
    );
    final answer = await app.handleJson({
      'id': 7,
      'kind': UsageRefresh.name,
      'arguments': {'accountKey': 'codex@nowhere'},
    });
    expect(answer['id'], 7);
    expect((answer['refusal'] as Map)['code'], DataRefusalCode.notFound.name);
    expect(vendor.asked, isEmpty);
  });

  test('agents.list carries each account\'s state', () async {
    final before = app.handle(const AgentsList()).value.usage.single;
    expect(before.accountKey, account);
    expect(before.usage, isNull, reason: 'never read yet');

    await app.handleLater(const UsageRefresh());
    final answer = app.handleJson({
      'id': 3,
      'kind': AgentsList.name,
      'arguments': const <String, Object?>{},
    });
    final snapshot = AgentsSnapshot.fromJson(
      ((answer as Map<String, Object?>)['result'] as Map)
          .cast<String, Object?>(),
    );
    expect(snapshot.usage.single.usage!.windows.single.percent, 20);
    expect(jsonEncode(answer), contains(account));
  });

  test('an agent whose adapter reads no usage is not an account; two installs '
      'in one place are one', () async {
    record([
      installation('claude1', AgentIds.claudeCode),
      installation('claude2', AgentIds.claudeCode, path: '/opt/claude'),
      installation('codex1', AgentIds.codex),
    ]);
    final usage = ServerUsage(
      data: service,
      service: vendor,
      registry: const AgentRegistry([ClaudeCodeAdapter(), _NoUsageCodex()]),
      clock: clock,
    );
    expect(usage.accounts().map((i) => i.id), ['claude1']);
    expect(usage.states().map((s) => s.accountKey), [account]);
    await expectLater(
      usage.refresh(accountKey: 'codex@$localHostEnvironmentId'),
      refused(DataRefusalCode.notFound),
    );
    await usage.refresh();
    expect(vendor.asked.map((i) => i.agentId), [AgentIds.claudeCode]);
  });

  test('a session row moving asks again — free inside the floor', () async {
    work.usage.start();
    await pumpEventQueue();
    expect(vendor.asked, hasLength(1), reason: 'the schedule reads at start');

    app.handle(
      const ProjectCreate(
        projectName: 'P',
        root: EnvironmentPath(
          environmentId: localHostEnvironmentId,
          path: '/src/p',
        ),
      ),
    );
    final checkout = app
        .handle(const WorkspaceList())
        .value
        .repositories
        .single;
    Session session(String id) => Session(
      id: id,
      repositoryId: checkout.id,
      agentInstallationId: 'claude1',
      title: 'Work',
      useWorktree: false,
      status: SessionStatus.created,
      createdAt: clock.nowUtc(),
    );

    clock.advance(const Duration(minutes: 1));
    app.handle(SessionCreate(session('s1')));
    await pumpEventQueue();
    expect(vendor.asked, hasLength(1), reason: 'inside the floor: memory');

    clock.advance(const Duration(minutes: 3));
    vendor.answer = (_) => reading(35);
    app.handle(SessionCreate(session('s2')));
    await pumpEventQueue();
    expect(vendor.asked, hasLength(2));
    expect(work.usage.states().single.usage!.windows.single.percent, 35);
    expect(
      toldChanges()
          .whereType<UsageStateChanged>()
          .last
          .state
          .usage!
          .windows
          .single
          .percent,
      35,
    );

    work.usage.stop();
    clock.advance(const Duration(minutes: 10));
    app.handle(SessionCreate(session('s3')));
    await pumpEventQueue();
    expect(vendor.asked, hasLength(2), reason: 'stopped: nothing follows');
  });
}

/// Codex's descriptor with no capability at all — usage included.
class _NoUsageCodex extends AgentAdapter {
  const _NoUsageCodex();

  @override
  AgentDescriptor get descriptor => codexDescriptor;
}
