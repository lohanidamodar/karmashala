import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart'
    show BackgroundRun, BackgroundRunKind, BackgroundRunState;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry;
import 'package:karmashala_host/src/attention/quiet_threshold.dart';
import 'package:karmashala_host/src/attention/server_session_status.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 10, 8, 9);
const _after = Duration(minutes: 15);

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// **A session that goes quiet is told so, by the server**: working, with
/// nothing new for the threshold, and waiting on nothing but itself.
void main() {
  late _Clock clock;
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late List<WatchedSession> watched;
  late Map<String, HostedAgentStatus> hosted;
  late bool exempt;
  late List<SessionStatusEntry> spells;

  const row = WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'conv-1'),
    label: 'Hosted',
    openId: 'row-1',
    imported: false,
  );

  setUp(() {
    clock = _Clock(_start);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [row];
    hosted = {};
    exempt = false;
    spells = [];
  });

  ServerSessionStatus build({
    Duration after = _after,
    Future<List<BackgroundRun>> Function(WatchedSession session)?
    backgroundRunsOf,
  }) => ServerSessionStatus(
    statusService: AgentStatusService(
      registry: AgentRegistry.builtIn,
      hookReports: reports,
      clock: clock,
    ),
    agents: AgentRegistry.builtIn,
    loadSessions: () => watched,
    clock: clock,
    heldByHost: (session) => hosted.containsKey(session.openId),
    hostStatusFor: (session) => hosted[session.openId],
    backgroundRunsOf: backgroundRunsOf,
    quietAfter: () => after,
    quietExempt: (_) => exempt,
    onQuiet: spells.add,
  );

  /// The host's reading of row-1: [status], last active at [active].
  void host(AgentActivityStatus status, {required DateTime active}) {
    hosted['row-1'] = HostedAgentStatus(
      sessionId: 'row-1',
      report: AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'conv-1',
        status: status,
        source: AgentStatusSource.hook,
        observedAt: clock.now,
      ),
      activeAt: active,
    );
  }

  Future<void> at(ServerSessionStatus status, Duration offset) async {
    clock.now = _start.add(offset);
    await status.cycle();
    await pumpEventQueue();
  }

  DateTime? quietOf(ServerSessionStatus status) =>
      status.reportForOpenId('row-1')?.quietSince;

  test('working with nothing new for the threshold is quiet, and says since '
      'when', () async {
    host(AgentActivityStatus.working, active: _start);
    final status = build();
    final told = <DateTime?>[];
    status.statusChanges.listen((e) => told.add(e.report.quietSince));

    await at(status, Duration.zero);
    await at(status, _after - const Duration(seconds: 1));
    expect(quietOf(status), isNull);

    await at(status, _after);
    expect(quietOf(status), _start);
    expect(told.last, _start, reason: 'every client is told');
    await status.close();
  });

  test('not while its sub-sessions work, or a usage limit holds it', () async {
    host(AgentActivityStatus.working, active: _start);
    exempt = true;
    final status = build();
    await at(status, Duration.zero);
    await at(status, _after * 2);
    expect(quietOf(status), isNull);

    exempt = false;
    await at(status, _after * 2 + const Duration(seconds: 2));
    expect(quietOf(status), _start, reason: 'the children finished');
    exempt = true;
    await at(status, _after * 2 + const Duration(seconds: 4));
    expect(quietOf(status), isNull, reason: 'a child started again');
    await status.close();
  });

  test('not while it waits on the person', () async {
    host(AgentActivityStatus.awaitingApproval, active: _start);
    final status = build();
    await at(status, Duration.zero);
    await at(status, _after * 3);
    expect(quietOf(status), isNull);
    await status.close();
  });

  test('activity clears it at once, and a new spell starts the clock '
      'again', () async {
    host(AgentActivityStatus.working, active: _start);
    final status = build();
    await at(status, Duration.zero);
    await at(status, _after);
    expect(quietOf(status), _start);

    // A screen that changed, a hook or a report: the host's activity moves.
    final active = _start.add(_after + const Duration(seconds: 5));
    host(AgentActivityStatus.working, active: active);
    await at(status, _after + const Duration(seconds: 6));
    expect(quietOf(status), isNull);

    await at(status, _after * 2);
    expect(quietOf(status), isNull);
    await at(status, _after * 2 + const Duration(seconds: 5));
    expect(quietOf(status), active);
    await status.close();
  });

  test(
    'one inbox item per quiet spell, however many cycles it lasts',
    () async {
      host(AgentActivityStatus.working, active: _start);
      final status = build();
      await at(status, Duration.zero);
      for (var minute = 15; minute < 40; minute++) {
        await at(status, Duration(minutes: minute));
      }
      expect(spells, hasLength(1));
      expect(spells.single.session.openId, 'row-1');
      expect(spells.single.report.quietSince, _start);

      final active = _start.add(const Duration(minutes: 40));
      host(AgentActivityStatus.working, active: active);
      await at(status, const Duration(minutes: 40));
      await at(status, const Duration(minutes: 56));
      expect(spells, hasLength(2));
      expect(spells.last.report.quietSince, active);
      await status.close();
    },
  );

  test('a hook on a session the server does not run is activity', () async {
    watched = [
      const WatchedSession(
        key: AgentSessionKey(AgentIds.claudeCode, 'hook-1'),
        label: 'Hooked',
        openId: 'row-hook',
        imported: false,
      ),
    ];
    void hook(String event) {
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: event,
        body: '{"session_id":"hook-1"}',
      );
    }

    // Shorter than a hook stays believed with nothing behind it.
    const short = Duration(minutes: 2);
    final status = build(after: short);
    hook('UserPromptSubmit');
    await at(status, Duration.zero);
    await at(status, short);
    expect(status.reportForOpenId('row-hook')?.quietSince, _start);

    // The same word again — a tool call's hook — is still news of life.
    clock.now = _start.add(short + const Duration(seconds: 1));
    hook('PreToolUse');
    status.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'hook-1'));
    expect(status.reportForOpenId('row-hook')?.quietSince, isNull);
    await status.close();
  });

  group('background work', () {
    BackgroundRun run(String description) => BackgroundRun(
      id: description,
      kind: BackgroundRunKind.agent,
      state: BackgroundRunState.running,
      description: description,
    );

    test('is not quiet while its runs still move', () async {
      host(AgentActivityStatus.idle, active: _start);
      var runs = [run('build')];
      final status = build(backgroundRunsOf: (_) async => runs);
      await at(status, Duration.zero);
      await at(status, const Duration(seconds: 2));
      expect(
        status.reportForOpenId('row-1')?.status,
        AgentActivityStatus.working,
      );

      // A second run starts ten minutes in: the work moved.
      await at(status, const Duration(minutes: 10));
      runs = [run('build'), run('tests')];
      await at(status, const Duration(minutes: 10, seconds: 2));
      await at(status, const Duration(minutes: 10, seconds: 4));
      await at(status, _after + const Duration(minutes: 1));
      expect(quietOf(status), isNull);
      await status.close();
    });

    test('is quiet when nothing in it moves for the threshold', () async {
      host(AgentActivityStatus.idle, active: _start);
      final status = build(backgroundRunsOf: (_) async => [run('build')]);
      await at(status, Duration.zero);
      await at(status, const Duration(seconds: 2));
      await at(status, _after + const Duration(seconds: 2));
      expect(
        status.reportForOpenId('row-1')?.status,
        AgentActivityStatus.working,
      );
      expect(quietOf(status), isNotNull);
      await status.close();
    });
  });

  group('the threshold', () {
    test('defaults to 15 minutes, reads the setting, clamps it', () {
      expect(quietAfterFrom(null), kDefaultQuietAfter);
      expect(quietAfterFrom('{"quietAfterMinutes": 30}'), _after * 2);
      expect(
        quietAfterFrom('{"quietAfterMinutes": 0}'),
        const Duration(minutes: 1),
      );
      expect(quietAfterFrom('{"quietAfterMinutes": "x"}'), kDefaultQuietAfter);
      expect(quietAfterFrom('not json'), kDefaultQuietAfter);
    });

    test('a probe shortens it in seconds', () {
      expect(
        quietAfterFrom('{"quietAfterMinutes": 30}', overrideSeconds: '20'),
        const Duration(seconds: 20),
      );
      expect(quietAfterFrom(null, overrideSeconds: 'no'), kDefaultQuietAfter);
    });

    test('is read again only once it is stale', () {
      var reads = 0;
      var now = _start;
      final threshold = QuietThreshold(
        readSettings: () {
          reads++;
          return null;
        },
        now: () => now,
      );
      threshold();
      threshold();
      expect(reads, 1);
      now = now.add(const Duration(seconds: 31));
      threshold();
      expect(reads, 2);
    });
  });
}
