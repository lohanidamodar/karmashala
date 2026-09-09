import 'dart:io';

import 'package:karmashala/src/features/agents/application/agent_hook_spool_drainer.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_spool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The loop that stands in for the `POST` a WSL agent cannot make.
///
/// Two things it must get right beyond "reads the files": it must not resurrect
/// a distribution the user shut down, and it must not stop polling one that
/// came back.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('karmashala_drainer_'));
  // Guarded the way the lifecycle test's is: a case that has already failed
  // may have taken its own directory with it, and a teardown that then throws
  // buries the failure that matters under a `PathNotFoundException`.
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone, or a file inside it went while this walked.
    }
  });

  void write(String name, {String event = 'Stop'}) => File(
    p.join(dir.path, name),
  ).writeAsStringSync('agent=claudeCode\nevent=$event\n\n{"session_id":"s"}');

  AgentHookSpoolSource source({String? distribution = 'Ubuntu'}) =>
      AgentHookSpoolSource(
        environmentId: 'wsl:Ubuntu',
        directory: dir,
        wslDistribution: distribution,
      );

  test('drains what is there, and hands each payload on once', () async {
    final seen = <AgentHookSpoolEvent>[];
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      runningDistributions: () async => {'Ubuntu'},
    );
    addTearDown(drainer.dispose);
    drainer.watch([source()]);
    write('1-0.json');

    await drainer.drainOnce();
    await drainer.drainOnce();

    expect(seen.map((e) => e.event), ['Stop']);
  });

  test('a distribution that is not running is not listed at all', () async {
    // Listing `\\wsl.localhost\<distro>` is served by a daemon *inside* that
    // distribution, so it starts one that is stopped. An app that quietly
    // resurrects a distribution every 400 ms after `wsl --shutdown` is a worse
    // neighbour than one that misses a hook — and it misses nothing, because a
    // distribution with no processes has no agent to fire one.
    final seen = <AgentHookSpoolEvent>[];
    var asked = 0;
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      spool: _RecordingSpool(),
      runningDistributions: () async {
        asked++;
        return {'Debian'};
      },
    );
    addTearDown(drainer.dispose);
    drainer.watch([source()]);
    write('1-0.json');

    await drainer.drainOnce();

    expect(seen, isEmpty);
    expect(asked, 1);
    expect(
      _RecordingSpool.listed,
      isEmpty,
      reason: 'not even the listing, which is what would wake it',
    );
    expect(
      File(p.join(dir.path, '1-0.json')).existsSync(),
      isTrue,
      reason: 'and the payload is still there when it comes back',
    );
  });

  test('a distribution that comes back is drained again', () async {
    final seen = <AgentHookSpoolEvent>[];
    // Another distribution is up, so the answer is trusted rather than read as
    // "the query failed" — see the fail-open case below.
    var running = {'Debian'};
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      runningDistributions: () async => running,
      // No caching between the two passes below: the point is the transition,
      // not the refresh interval, which has its own case.
      runningRefresh: Duration.zero,
    );
    addTearDown(drainer.dispose);
    drainer.watch([source()]);
    write('1-0.json');

    await drainer.drainOnce();
    expect(seen, isEmpty);

    running = {'Ubuntu'};
    await drainer.drainOnce();

    expect(seen.map((e) => e.event), ['Stop']);
  });

  test('the running set is asked for at most once per refresh', () async {
    // It costs a `wsl.exe`, measured at 188 ms. Asking on every 400 ms tick
    // would spend half of one.
    var asked = 0;
    final drainer = AgentHookSpoolDrainer(
      onEvent: (_) {},
      runningDistributions: () async {
        asked++;
        return {'Ubuntu'};
      },
      runningRefresh: const Duration(minutes: 5),
    );
    addTearDown(drainer.dispose);
    drainer.watch([source()]);

    await drainer.drainOnce();
    await drainer.drainOnce();
    await drainer.drainOnce();

    expect(asked, 1);
  });

  test('a running set it could not read means poll everything', () async {
    // Fails open. Polling a stopped distribution costs a wake-up; skipping a
    // running one costs every status it would have reported.
    final seen = <AgentHookSpoolEvent>[];
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      runningDistributions: () async => const {},
    );
    addTearDown(drainer.dispose);
    drainer.watch([source()]);
    write('1-0.json');

    await drainer.drainOnce();

    expect(seen, hasLength(1));
  });

  test('a source with no distribution is never gated', () async {
    // Nothing produces one today — the spool transport is WSL's — but a source
    // that names no distribution must not be silently skipped by a gate that
    // cannot answer for it.
    var asked = 0;
    final seen = <AgentHookSpoolEvent>[];
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      runningDistributions: () async {
        asked++;
        return {'Ubuntu'};
      },
    );
    addTearDown(drainer.dispose);
    drainer.watch([source(distribution: null)]);
    write('1-0.json');

    await drainer.drainOnce();

    expect(seen, hasLength(1));
    expect(asked, 0, reason: 'and it spends no process finding that out');
  });

  test('watching nothing arms no tick', () async {
    // Counted: the loop is never armed at all. This used to sleep 60 ms and
    // assert that a 5 ms timer had not asked anything in that window, which
    // says the same thing only on a machine that was listening.
    final loop = _StepSchedule();
    var asked = 0;
    final drainer = AgentHookSpoolDrainer(
      onEvent: (_) {},
      interval: const Duration(milliseconds: 5),
      runningDistributions: () async {
        asked++;
        return {'Ubuntu'};
      },
      schedule: loop.arm,
      cancelSchedule: loop.cancel,
    );
    addTearDown(drainer.dispose);

    drainer.watch(const []);

    expect(loop.armedAt, isEmpty, reason: 'nothing to poll, nothing armed');
    expect(asked, 0);
    expect(drainer.sources, isEmpty);
  });

  test('the tick it arms is what reads the payload, not the caller', () async {
    // **The loop is stepped, not waited on.** This slept 120 ms and expected
    // twelve 10 ms ticks to have delivered one payload; alone and unloaded it
    // still read `[]` about one run in three, which measured the scheduler
    // rather than the drainer. What it means to say is that the drainer arms
    // its own periodic tick at its own interval and that *that* tick — nobody
    // calling `drainOnce` — is what reads the file. Both halves are counted.
    final loop = _StepSchedule();
    final seen = <AgentHookSpoolEvent>[];
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      interval: const Duration(milliseconds: 10),
      runningDistributions: () async => {'Ubuntu'},
      schedule: loop.arm,
      cancelSchedule: loop.cancel,
    );
    addTearDown(drainer.dispose);
    drainer.watch([source()]);
    write('1-0.json');

    expect(loop.armedAt, [const Duration(milliseconds: 10)]);
    loop.tick();
    // Awaits the drain that tick started, not a duration.
    await drainer.settled;

    expect(seen, hasLength(1));
  });

  test('disposing stops it, so shutdown is not racing a share', () async {
    final loop = _StepSchedule();
    final seen = <AgentHookSpoolEvent>[];
    final drainer = AgentHookSpoolDrainer(
      onEvent: seen.add,
      interval: const Duration(milliseconds: 5),
      runningDistributions: () async => {'Ubuntu'},
      schedule: loop.arm,
      cancelSchedule: loop.cancel,
    );
    drainer.watch([source()]);
    drainer.dispose();
    write('1-0.json');

    // The tick was cancelled, and firing the one it had armed anyway — the
    // shape of a callback already in the queue when `dispose` ran — reads
    // nothing.
    expect(loop.cancelled, 1);
    loop.tick();
    await drainer.settled;

    expect(seen, isEmpty);
    expect(drainer.sources, isEmpty);
  });
}

/// A spool that records whether the directory was listed at all.
class _RecordingSpool extends AgentHookSpool {
  const _RecordingSpool();

  static final listed = <String>[];

  @override
  Future<List<AgentHookSpoolEvent>> drain(
    Directory directory, {
    int limit = 64,
  }) {
    listed.add(directory.path);
    return super.drain(directory, limit: limit);
  }
}

/// The drainer's loop, held rather than run.
///
/// Records every interval armed and lets a case fire the tick itself, so a
/// case asserts *that the loop was armed and what firing it did* instead of
/// waiting long enough for a real `Timer` to have fired on this machine.
class _StepSchedule {
  final List<Duration> armedAt = <Duration>[];
  int cancelled = 0;
  void Function()? _tick;

  Object arm(Duration interval, void Function() tick) {
    armedAt.add(interval);
    _tick = tick;
    return #handle;
  }

  void cancel(Object handle) => cancelled++;

  /// Fires the armed tick. Deliberately still callable after [cancel]: a
  /// callback already queued when `dispose` ran is exactly the case
  /// `disposing stops it` is about.
  void tick() => _tick?.call();
}
