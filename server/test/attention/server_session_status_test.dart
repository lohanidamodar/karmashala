import 'dart:async';
import 'dart:math' as math;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart'
    show BackgroundRun, BackgroundRunKind, BackgroundRunState;
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry, WatchCoverage;
import 'package:karmashala_host/src/attention/server_session_status.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 9, 27, 9);

/// A transcript source with no disk behind it, so a 500-session fairness
/// proof runs in milliseconds and counts exactly what was asked for.
class _FakeStateSource extends AgentStateFileStatusSource {
  final Map<String, Map<String, Object?>> records = {};
  final Map<String, DateTime> modified = {};
  final Map<String, int> callsByPath = {};
  int calls = 0;
  int reads = 0;
  int inFlight = 0;
  int peakInFlight = 0;
  Duration delay = Duration.zero;

  @override
  Future<StateFileSnapshot?> probe(
    String filePath, {
    StateFileSnapshot? known,
  }) async {
    calls++;
    callsByPath[filePath] = (callsByPath[filePath] ?? 0) + 1;
    inFlight++;
    peakInFlight = math.max(peakInFlight, inFlight);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final record = records[filePath];
      if (record == null) return null;
      final mtime = modified[filePath] ?? _start;
      if (known != null && known.modified == mtime) return known;
      reads++;
      return StateFileSnapshot(
        modified: mtime,
        size: record.length,
        record: record,
      );
    } finally {
      inFlight--;
    }
  }
}

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// The server's status registry (slice 5c) — the app's registry moved, fed
/// by the hooks the server takes, its own reading of the agents it runs and
/// the transcripts on its machine. The coverage guarantees the app's suite
/// proved, proved again here, plus what is new: a session the server runs is
/// its own reading, never a hook or a transcript.
void main() {
  late AgentHookReports reports;
  late AgentHookReceiver receiver;
  late AgentStatusService service;
  late _FakeStateSource source;
  late _Clock clock;
  late List<WatchedSession> watched;
  late Set<String> visible;
  late Map<String, HostedAgentStatus> hosted;

  setUp(() {
    clock = _Clock(_start);
    reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    service = AgentStatusService(
      registry: AgentRegistry.builtIn,
      hookReports: reports,
      clock: clock,
    );
    source = _FakeStateSource();
    watched = [];
    visible = {};
    hosted = {};
  });

  ServerSessionStatus build({
    int probeBudget = kStatusProbeBudget,
    int probeConcurrency = kStatusProbeConcurrency,
    Future<Map<String, String>> Function()? resolveTranscripts,
    List<String>? log,
    Future<List<BackgroundRun>> Function(WatchedSession session)?
    backgroundRunsOf,
  }) => ServerSessionStatus(
    statusService: service,
    agents: AgentRegistry.builtIn,
    loadSessions: () => watched,
    clock: clock,
    stateFileSource: source,
    probeBudget: probeBudget,
    probeConcurrency: probeConcurrency,
    resolveTranscripts: resolveTranscripts,
    visibleSessionIds: () => visible,
    heldByHost: (session) => hosted.containsKey(session.openId),
    hostStatusFor: (session) => hosted[session.openId],
    log: log?.add,
    backgroundRunsOf: backgroundRunsOf,
  );

  void addTranscriptSessions(int count, {String prefix = 'cli'}) {
    for (var i = 0; i < count; i++) {
      final path = 'store/$prefix-$i.jsonl';
      source.records[path] = {'type': 'assistant'};
      watched.add(
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, '$prefix-$i'),
          label: 'Session $i',
          openId: 'row-$prefix-$i',
          imported: true,
          stateFilePath: path,
        ),
      );
    }
  }

  void addHookedSessions(int count, {String event = 'PreToolUse'}) {
    for (var i = 0; i < count; i++) {
      watched.add(
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'hook-$i'),
          label: 'Hooked $i',
          openId: 'row-hook-$i',
          imported: false,
        ),
      );
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: event,
        body: '{"session_id":"hook-$i"}',
      );
    }
  }

  group('nothing is capped by list position', () {
    for (final count in [100, 500]) {
      test(
        '$count hook-backed sessions are all covered in one cycle',
        () async {
          addHookedSessions(count);
          final status = build(probeBudget: 1);

          final entries = await status.cycle();

          expect(entries, hasLength(count));
          for (var i = 0; i < count; i++) {
            final report = status.reportForKey(
              AgentSessionKey(AgentIds.claudeCode, 'hook-$i'),
            );
            expect(report?.status, AgentActivityStatus.working, reason: '$i');
            expect(report?.source, AgentStatusSource.hook);
          }
          expect(status.probes, 0, reason: 'a hook needs no disk read');
          await status.close();
        },
      );
    }
  });

  group('the transcript probe budget', () {
    test('spends exactly the budget when more sessions want one', () async {
      addTranscriptSessions(100);
      final status = build(probeBudget: 10);
      await status.cycle();
      expect(source.calls, 10);
      await status.close();
    });

    test('the rotation reaches all 500 sessions within ceil(500/24)', () async {
      addTranscriptSessions(500);
      final status = build();
      for (var i = 0; i < (500 / kStatusProbeBudget).ceil(); i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await status.cycle();
      }
      final entries = status.entries;
      expect(entries, hasLength(500));
      for (final entry in entries) {
        expect(
          entry.report.status,
          AgentActivityStatus.idle,
          reason: entry.openId,
        );
        expect(entry.report.source, AgentStatusSource.stateFile);
      }
      await status.close();
    });

    test('a busy priority tier cannot starve the rotation', () async {
      addTranscriptSessions(90);
      visible = {for (var i = 0; i < 30; i++) 'cli-$i'};
      final status = build(probeBudget: 12);
      for (var i = 0; i < 15; i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await status.cycle();
      }
      final starved = [
        for (var i = 30; i < 90; i++)
          if (source.callsByPath['store/cli-$i.jsonl'] == null) i,
      ];
      expect(starved, isEmpty);
      await status.close();
    });

    test('probes run concurrently, capped', () async {
      addTranscriptSessions(20);
      source.delay = const Duration(milliseconds: 2);
      final status = build(probeBudget: 20, probeConcurrency: 4);
      await status.cycle();
      expect(source.peakInFlight, 4);
      await status.close();
    });

    test('an unchanged transcript costs a stat and no read', () async {
      addTranscriptSessions(4);
      final status = build(probeBudget: 10);
      await status.cycle();
      await status.cycle();
      expect(source.calls, 8);
      expect(source.reads, 4);
      await status.close();
    });
  });

  group('state survives a cycle that did not sample it', () {
    test('a change is seen when the rotation comes back round', () async {
      addTranscriptSessions(3);
      final status = build(probeBudget: 1);
      const first = AgentSessionKey(AgentIds.claudeCode, 'cli-0');
      await status.cycle();
      expect(status.reportForKey(first)?.status, AgentActivityStatus.idle);

      source.records['store/cli-0.jsonl'] = {'type': 'user'};
      source.modified['store/cli-0.jsonl'] = _start.add(
        const Duration(seconds: 1),
      );
      for (var i = 0; i < 3; i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await status.cycle();
      }
      expect(status.reportForKey(first)?.status, AgentActivityStatus.working);
      await status.close();
    });

    test('only leaving the watch set forgets a session, and says so', () async {
      addTranscriptSessions(2);
      final status = build();
      final removed = <String>[];
      status.removals.listen(removed.add);
      await status.cycle();
      watched.removeAt(0);
      await status.cycle();
      expect(
        status.reportForKey(
          const AgentSessionKey(AgentIds.claudeCode, 'cli-0'),
        ),
        isNull,
      );
      expect(status.trackedCount, 1);
      expect(removed, ['row-cli-0']);
      await status.close();
    });
  });

  group('transcript paths are found once, centrally', () {
    test('one walk answers for every session that needs a path', () async {
      var walks = 0;
      for (var i = 0; i < 50; i++) {
        source.records['found/cli-$i.jsonl'] = {'type': 'assistant'};
        watched.add(
          WatchedSession(
            key: AgentSessionKey(AgentIds.claudeCode, 'cli-$i'),
            label: 'Native $i',
            openId: 'row-$i',
            imported: false,
          ),
        );
      }
      final status = build(
        probeBudget: 50,
        resolveTranscripts: () async {
          walks++;
          return {
            for (var i = 0; i < 50; i++)
              '${AgentIds.claudeCode}/cli-$i': 'found/cli-$i.jsonl',
          };
        },
      );
      await status.cycle();
      expect(walks, 1);
      for (final entry in status.entries) {
        expect(entry.report.status, AgentActivityStatus.idle);
      }
      expect(status.transcriptPathForOpenId('row-7'), 'found/cli-7.jsonl');
      await status.close();
    });

    test('a session its agent never named asks for no walk at all', () async {
      var walks = 0;
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'row-0'),
          label: 'Just launched',
          openId: 'row-0',
          imported: false,
        ),
      );
      final status = build(
        resolveTranscripts: () async {
          walks++;
          return const {};
        },
      );
      await status.cycle();
      expect(walks, 0);
      await status.close();
    });
  });

  group('coverage is reported', () {
    test(
      'a cycle says how much it reached, and only when that moved',
      () async {
        addHookedSessions(3);
        addTranscriptSessions(2);
        final status = build();
        final told = <WatchCoverage>[];
        status.coverageChanges.listen(told.add);
        await status.cycle();
        await status.cycle();
        expect(told, hasLength(1), reason: 'the same reach is not news');
        expect(told.single.tracked, 5);
        expect(told.single.hookAnswered, 3);
        expect(told.single.probeCandidates, 2);
        expect(told.single.isBehind, isFalse);
        await status.close();
      },
    );

    test('a rotation that cannot keep up says so in the log, once', () async {
      addTranscriptSessions(400);
      final log = <String>[];
      final status = build(probeBudget: 3, log: log);
      await status.cycle();
      await status.cycle();
      expect(status.coverage!.isBehind, isTrue);
      expect(log.where((line) => line.contains('behind')), hasLength(1));
      await status.close();
    });
  });

  group('a session the server runs is its own reading', () {
    test('no hook and no transcript are consulted for it', () async {
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'conv-1'),
          label: 'Hosted',
          openId: 'row-1',
          imported: false,
          stateFilePath: 'store/conv-1.jsonl',
        ),
      );
      source.records['store/conv-1.jsonl'] = {'type': 'user'};
      hosted['row-1'] = HostedAgentStatus(
        sessionId: 'row-1',
        report: AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'conv-1',
          status: AgentActivityStatus.awaitingApproval,
          source: AgentStatusSource.terminalGrid,
          observedAt: _start,
        ),
      );
      final status = build();
      await status.cycle();
      expect(
        status.reportForOpenId('row-1')?.status,
        AgentActivityStatus.awaitingApproval,
      );
      expect(source.calls, 0, reason: 'the server read its own screen');
      await status.close();
    });

    test('its reading moving is folded in at once, with no cycle', () async {
      watched.add(
        const WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'conv-1'),
          label: 'Hosted',
          openId: 'row-1',
          imported: false,
        ),
      );
      hosted['row-1'] = HostedAgentStatus(
        sessionId: 'row-1',
        report: AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'conv-1',
          status: AgentActivityStatus.working,
          source: AgentStatusSource.hook,
          observedAt: _start,
        ),
      );
      final status = build();
      final events = <SessionStatusEntry>[];
      status.hookChanges.listen(events.add);
      // Never cycled: a row the server speaks of joins from memory.
      status.hostStatusMoved('row-1');
      expect(events.single.report.status, AgentActivityStatus.working);
      expect(status.cycles, 0);

      hosted['row-1'] = HostedAgentStatus(
        sessionId: 'row-1',
        report: AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'conv-1',
          status: AgentActivityStatus.idle,
          source: AgentStatusSource.hook,
          observedAt: _start.add(const Duration(seconds: 3)),
        ),
      );
      status.hostStatusMoved('row-1');
      expect(events.last.report.status, AgentActivityStatus.idle);
      expect(status.cycles, 0);
      await status.close();
    });
  });

  group('a hook does not wait for a cycle', () {
    test('it is applied in place, told once, and not again', () async {
      addHookedSessions(1, event: 'UserPromptSubmit');
      final status = build();
      await status.cycle();
      final moves = <SessionStatusEntry>[];
      status.hookChanges.listen(moves.add);
      final cycles = status.cycles;

      clock.now = clock.now.add(const Duration(seconds: 2));
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: 'Stop',
        body: '{"session_id":"hook-0"}',
      );
      status.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'hook-0'));
      expect(moves.single.report.status, AgentActivityStatus.idle);
      expect(status.cycles, cycles, reason: 'no cycle, no disk');

      status.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'hook-0'));
      expect(moves, hasLength(1), reason: 'the same evidence is no move');
      await status.close();
    });

    test('a hook for a session nobody watches asks for one cycle', () async {
      final status = build();
      status.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'x'));
      status.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'y'));
      await Future<void>.delayed(Duration.zero);
      expect(status.cycles, 1, reason: 'rationed by the hook cycle floor');
      expect(
        status.reportForKey(const AgentSessionKey(AgentIds.claudeCode, 'x')),
        isNull,
        reason: 'nobody watches it, so nobody holds a status for it',
      );
      await status.close();
    });
  });

  group('a session waiting on its background runs is working', () {
    const row = WatchedSession(
      key: AgentSessionKey(AgentIds.claudeCode, 'conv-1'),
      label: 'Two background agents',
      openId: 'row-1',
      imported: false,
    );

    BackgroundRun run(BackgroundRunState state, {DateTime? endedAt}) =>
        BackgroundRun(
          id: 'a1',
          kind: BackgroundRunKind.agent,
          state: state,
          description: 'Sleep 90 then report',
          endedAt: endedAt,
        );

    void say(AgentActivityStatus status, Duration at) {
      clock.now = _start.add(at);
      hosted['row-1'] = HostedAgentStatus(
        sessionId: 'row-1',
        report: AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'conv-1',
          status: status,
          source: AgentStatusSource.hook,
          observedAt: clock.now,
        ),
      );
    }

    test('until the last ends and the turn after it ends', () async {
      watched.add(row);
      var runs = [run(BackgroundRunState.running)];
      final status = build(backgroundRunsOf: (_) async => runs);
      final moves = <AgentActivityStatus>[];
      status.statusChanges.listen((entry) => moves.add(entry.report.status));

      say(AgentActivityStatus.working, Duration.zero);
      status.hostStatusMoved('row-1');
      say(AgentActivityStatus.idle, const Duration(seconds: 3));
      status.hostStatusMoved('row-1');
      await pumpEventQueue();
      final held = status.reportForOpenId('row-1')!;
      expect(held.status, AgentActivityStatus.working);
      expect(held.inFlight, ['Sleep 90 then report']);

      clock.now = _start.add(const Duration(seconds: 60));
      await status.cycle();
      await pumpEventQueue();
      expect(
        status.reportForOpenId('row-1')!.status,
        AgentActivityStatus.working,
      );

      runs = [
        run(
          BackgroundRunState.completed,
          endedAt: _start.add(const Duration(seconds: 90)),
        ),
      ];
      clock.now = _start.add(const Duration(seconds: 91));
      await status.cycle();
      await pumpEventQueue();
      expect(
        status.reportForOpenId('row-1')!.status,
        AgentActivityStatus.working,
        reason: 'the agent has not yet taken its turn over the report',
      );

      say(AgentActivityStatus.working, const Duration(seconds: 92));
      status.hostStatusMoved('row-1');
      say(AgentActivityStatus.idle, const Duration(seconds: 95));
      status.hostStatusMoved('row-1');
      await pumpEventQueue();
      expect(status.reportForOpenId('row-1')!.status, AgentActivityStatus.idle);
      expect(
        moves.where((s) => s == AgentActivityStatus.idle),
        hasLength(1),
        reason: 'one finish, at the end',
      );
      await status.close();
    });

    test('the same idle said again is not the turn after the run', () async {
      watched.add(row);
      var runs = [run(BackgroundRunState.running)];
      final status = build(backgroundRunsOf: (_) async => runs);
      say(AgentActivityStatus.working, Duration.zero);
      status.hostStatusMoved('row-1');
      say(AgentActivityStatus.idle, const Duration(seconds: 3));
      status.hostStatusMoved('row-1');
      await pumpEventQueue();

      runs = [
        run(
          BackgroundRunState.completed,
          endedAt: _start.add(const Duration(seconds: 90)),
        ),
      ];
      // A screen read restamps the idle it already showed.
      say(AgentActivityStatus.idle, const Duration(seconds: 91));
      clock.now = _start.add(const Duration(seconds: 93));
      await status.cycle();
      await pumpEventQueue();
      expect(
        status.reportForOpenId('row-1')!.status,
        AgentActivityStatus.working,
      );
      await status.close();
    });

    test('an idle with nothing in the background is told as it is', () async {
      watched.add(row);
      final status = build(backgroundRunsOf: (_) async => const []);
      final events = <SessionStatusEntry>[];
      status.hookChanges.listen(events.add);
      say(AgentActivityStatus.working, Duration.zero);
      status.hostStatusMoved('row-1');
      say(AgentActivityStatus.idle, const Duration(seconds: 3));
      status.hostStatusMoved('row-1');
      await pumpEventQueue();
      expect(events.last.report.status, AgentActivityStatus.idle);
      expect(
        events.where((e) => e.report.status == AgentActivityStatus.idle),
        hasLength(1),
      );
      await status.close();
    });

    test('a hooked session holds the same way', () async {
      addHookedSessions(1, event: 'UserPromptSubmit');
      final status = build(
        backgroundRunsOf: (_) async => [run(BackgroundRunState.running)],
      );
      await status.cycle();
      receiver.handle(
        agentId: AgentIds.claudeCode,
        event: 'Stop',
        body: '{"session_id":"hook-0"}',
      );
      status.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'hook-0'));
      await pumpEventQueue();
      expect(
        status.reportForOpenId('row-hook-0')!.status,
        AgentActivityStatus.working,
      );
      await status.close();
    });

    test('a history session is never read for them', () async {
      addTranscriptSessions(3);
      var asked = 0;
      final status = build(
        backgroundRunsOf: (_) async {
          asked++;
          return const [];
        },
      );
      await status.cycle();
      await status.cycle();
      await pumpEventQueue();
      expect(asked, 0);
      await status.close();
    });
  });
}
