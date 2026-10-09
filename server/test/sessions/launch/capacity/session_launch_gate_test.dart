import 'dart:async';

import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/launch/capacity/session_launch_gate.dart';
import 'package:test/test.dart';

class _Clock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 9, 12);
  @override
  DateTime nowUtc() => now;
}

/// A gate over a fake world: [live] is what holds a slot, [limits] what a
/// person set, [stored] the persisted queue.
class _World {
  _World({this.limits = LaunchLimits.none});

  LaunchLimits limits;
  final clock = _Clock();
  final live = <SlotHolder>[];
  final percents = <String, double?>{};
  String? stored;
  final started = <String>[];
  final cancelled = <String>[];
  var _ticks = 0;

  late SessionLaunchGate gate = build();

  SessionLaunchGate build() {
    final gate = SessionLaunchGate(
      limits: () => limits,
      occupants: () => List.of(live),
      clock: clock,
      readQueue: () => stored,
      writeQueue: (json) => stored = json,
      fiveHourPercent: (key) => percents[key],
      names: LaunchScopeNames(
        machine: (id) => id == 'wsl-arch' ? 'WSL · archlinux' : id,
      ),
    );
    gate.onGranted('session.start', (ticket, reservation) async {
      started.add(ticket.claim.sessionId!);
      live.add(
        holder(ticket.claim.sessionId!, env: ticket.claim.environmentId),
      );
    }, onCancelled: (ticket) => cancelled.add(ticket.claim.sessionId!));
    gate.start();
    return gate;
  }

  /// A claim for session [id]; each one later than the last.
  LaunchClaim claim(
    String id, {
    LaunchPriority priority = LaunchPriority.interactive,
    String env = 'windows',
    String account = 'claude@windows',
    String project = 'p1',
  }) {
    clock.now = clock.now.add(Duration(seconds: ++_ticks));
    return LaunchClaim(
      kind: 'session.start',
      priority: priority,
      environmentId: env,
      accountKey: account,
      projectId: project,
      label: id.toUpperCase(),
      sessionId: id,
      personStarted: priority == LaunchPriority.interactive,
    );
  }

  SlotHolder holder(
    String id, {
    String env = 'windows',
    String account = 'claude@windows',
    String project = 'p1',
  }) => SlotHolder(
    sessionId: id,
    label: id.toUpperCase(),
    environmentId: env,
    accountKey: account,
    projectId: project,
  );

  /// Grants [claim] and makes it live, as a launch would.
  void run(LaunchClaim claim) {
    final admission = gate.acquire(claim);
    expect(admission, isA<LaunchGranted>(), reason: '${claim.sessionId}');
    live.add(
      holder(
        claim.sessionId!,
        env: claim.environmentId,
        account: claim.accountKey,
        project: claim.projectId,
      ),
    );
    (admission as LaunchGranted).reservation.release();
  }

  void end(String id) {
    live.removeWhere((h) => h.sessionId == id);
    gate.pump();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('nothing set: every launch is granted', () {
    final world = _World();
    for (var i = 0; i < 10; i++) {
      world.run(world.claim('s$i'));
    }
    expect(world.gate.snapshot().waiters, isEmpty);
  });

  test('concurrent starts never exceed a limit', () {
    final world = _World(limits: const LaunchLimits(global: 2));
    // Reserved but not yet live: the reservations alone fill the limit.
    final a = world.gate.acquire(world.claim('a'));
    final b = world.gate.acquire(world.claim('b'));
    final c = world.gate.acquire(world.claim('c'));
    expect(a, isA<LaunchGranted>());
    expect(b, isA<LaunchGranted>());
    expect(c, isA<LaunchWaiting>());
    expect(
      (c as LaunchWaiting).reason,
      'Waiting for a slot: 2 of 2 are busy (A, B)',
    );
    expect(c.place, 1);
  });

  test('the wait names the machine, its holders and the place in line', () {
    final world = _World(limits: const LaunchLimits(machines: {'wsl-arch': 2}));
    world.run(world.claim('x', env: 'wsl-arch'));
    world.run(world.claim('y', env: 'wsl-arch'));
    world.run(world.claim('elsewhere'));
    final waiting =
        world.gate.acquire(world.claim('z', env: 'wsl-arch')) as LaunchWaiting;
    expect(
      waiting.reason,
      'Waiting for a slot: 2 of 2 on WSL · archlinux are busy (X, Y)',
    );
    final snapshot = world.gate.snapshot();
    expect(snapshot.running, 3);
    expect(snapshot.scopes.single.used, 2);
    expect(snapshot.waiterFor('z')!.place, 1);
  });

  test('a freed slot goes to the oldest interactive waiter first', () async {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('running'));
    final bg = world.gate.acquire(
      world.claim('bg', priority: LaunchPriority.background),
    );
    final person = world.gate.acquire(world.claim('person'));
    expect(bg, isA<LaunchWaiting>());
    expect(person, isA<LaunchWaiting>());
    expect(world.gate.snapshot().waiterFor('person')!.place, 1);
    expect(world.gate.snapshot().waiterFor('bg')!.place, 2);

    world.end('running');
    await _settle();
    expect(world.started, ['person']);
    world.end('person');
    await _settle();
    expect(world.started, ['person', 'bg']);
  });

  test('an interactive start goes ahead of background waiters', () {
    final world = _World(limits: const LaunchLimits(global: 2));
    world.run(world.claim('one'));
    world.run(world.claim('two'));
    world.gate.acquire(world.claim('bg', priority: LaunchPriority.background));
    world.end('two');
    // The freed slot went to the background waiter; a person's start after
    // it now waits — but ahead of any other background waiter.
    world.gate.acquire(world.claim('bg2', priority: LaunchPriority.background));
    final person = world.gate.acquire(world.claim('person')) as LaunchWaiting;
    expect(person.place, 1);
  });

  test('a blocked waiter is not overtaken through a shared scope', () async {
    final world = _World(
      limits: const LaunchLimits(global: 2, machines: {'wsl-arch': 1}),
    );
    world.run(world.claim('arch', env: 'wsl-arch'));
    // Waits on the machine; the one global slot left is promised to it.
    final first = world.gate.acquire(world.claim('first', env: 'wsl-arch'));
    final second = world.gate.acquire(world.claim('second'));
    expect(first, isA<LaunchWaiting>());
    expect(second, isA<LaunchWaiting>());
    expect(
      (second as LaunchWaiting).reason,
      'Waiting for a slot: 1 of 2 is busy (ARCH), and 1 is promised to '
      'launches ahead in line',
    );
    world.end('arch');
    await _settle();
    expect(world.started, ['first', 'second']);
  });

  test('Start anyway skips the limit and counts from then on', () async {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('one'));
    final waiting = world.gate.acquire(world.claim('two')) as LaunchWaiting;
    expect(world.gate.startAnyway(waiting.ticket.id), isTrue);
    await _settle();
    expect(world.started, ['two']);
    expect(world.gate.snapshot().running, 2);
    expect(world.gate.acquire(world.claim('three')), isA<LaunchWaiting>());
    // Ending one still leaves the limit reached.
    world.end('one');
    await _settle();
    expect(world.started, ['two']);
    world.end('two');
    await _settle();
    expect(world.started, ['two', 'three']);
  });

  test('a person may start anyway at acquire', () {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('one'));
    expect(
      world.gate.acquire(world.claim('two'), startAnyway: true),
      isA<LaunchGranted>(),
    );
  });

  test('the pause holds background work only, until it is lifted', () async {
    final world = _World(limits: const LaunchLimits(pauseBackground: true));
    world.run(world.claim('person'));
    final bg = world.gate.acquire(
      world.claim('bg', priority: LaunchPriority.background),
    );
    expect(
      (bg as LaunchWaiting).reason,
      'Waiting: new background work is paused',
    );
    world.limits = const LaunchLimits();
    world.gate.pump();
    await _settle();
    expect(world.started, ['bg']);
  });

  test('a cancelled waiter leaves the line and is told', () {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('one'));
    final waiting = world.gate.acquire(world.claim('two')) as LaunchWaiting;
    expect(world.gate.cancel(waiting.ticket.id), isTrue);
    expect(world.cancelled, ['two']);
    expect(world.gate.snapshot().waiters, isEmpty);
    expect(world.gate.cancel(waiting.ticket.id), isFalse);
  });

  test('a slot frees on end, failure, stop and archive alike', () async {
    // Each is the process leaving the live set; the gate counts the set.
    for (final how in ['end', 'fail', 'stop', 'archive']) {
      final world = _World(limits: const LaunchLimits(global: 1));
      world.run(world.claim('one'));
      world.gate.acquire(world.claim('two'));
      world.end('one');
      await _settle();
      expect(world.started, ['two'], reason: how);
    }
  });

  test('a launch that fails releases its reservation', () async {
    final world = _World(limits: const LaunchLimits(global: 1));
    final granted = world.gate.acquire(world.claim('one')) as LaunchGranted;
    expect(world.gate.acquire(world.claim('two')), isA<LaunchWaiting>());
    granted.reservation.release(); // the launch threw; nothing went live
    await _settle();
    expect(world.started, ['two']);
  });

  test('a reservation nobody released stops counting after its timeout', () {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.gate.acquire(world.claim('stuck'));
    expect(world.gate.acquire(world.claim('two')), isA<LaunchWaiting>());
    world.clock.now = world.clock.now.add(const Duration(minutes: 11));
    world.gate.pump();
    expect(world.gate.snapshot().waiters, isEmpty);
  });

  test('restart: the queue survives, and counting is rebuilt from what '
      'really runs', () async {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('one'));
    world.gate.acquire(world.claim('two'));
    world.gate.acquire(world.claim('bg', priority: LaunchPriority.background));
    final reserved = world.gate.acquire(world.claim('three'));
    expect(reserved, isA<LaunchWaiting>());

    // The server restarts: its reservations are gone; 'one' still runs.
    world.gate = world.build();
    final snapshot = world.gate.snapshot();
    expect(snapshot.running, 1);
    expect(
      [for (final w in snapshot.waiters) w.sessionId],
      ['two', 'three', 'bg'],
    );
    world.end('one');
    await _settle();
    expect(world.started, ['two']);
  });

  test('restart: a stale holder that no longer runs frees its slot', () async {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('one'));
    world.gate.acquire(world.claim('two'));
    world.live.clear(); // died with the server
    world.gate = world.build();
    await _settle();
    expect(world.started, ['two']);
  });

  test('a restored ticket of a kind nobody starts is dropped', () {
    final world = _World(limits: const LaunchLimits(global: 1));
    world.run(world.claim('one'));
    world.gate.acquire(
      const LaunchClaim(
        kind: 'pipeline.stage',
        priority: LaunchPriority.background,
        environmentId: 'windows',
        accountKey: 'claude@windows',
        projectId: 'p1',
        label: 'stage',
      ),
    );
    world.gate = world.build();
    expect(world.gate.snapshot().waiters, isEmpty);
  });

  test('lowering a limit leaves running sessions alone', () async {
    final world = _World(limits: const LaunchLimits(global: 3));
    world.run(world.claim('a'));
    world.run(world.claim('b'));
    world.run(world.claim('c'));
    world.limits = const LaunchLimits(global: 1);
    world.gate.pump();
    expect(world.live, hasLength(3));
    expect(world.gate.acquire(world.claim('d')), isA<LaunchWaiting>());
    world.end('a');
    world.end('b');
    await _settle();
    expect(world.started, isEmpty, reason: 'still 1 of 1');
    world.end('c');
    await _settle();
    expect(world.started, ['d']);
  });

  test('machine, account and project scopes combine: all must allow', () {
    final world = _World(
      limits: const LaunchLimits(
        machines: {'windows': 5},
        accounts: {'codex@windows': 1},
        projects: {'p2': 1},
      ),
    );
    world.run(world.claim('codex', account: 'codex@windows'));
    world.run(world.claim('p2', project: 'p2'));
    expect(
      world.gate.acquire(world.claim('codex2', account: 'codex@windows')),
      isA<LaunchWaiting>(),
    );
    expect(
      world.gate.acquire(world.claim('p2b', project: 'p2')),
      isA<LaunchWaiting>(),
    );
    expect(world.gate.acquire(world.claim('free')), isA<LaunchGranted>());
  });

  test('the usage hold: over the line holds background work; unknown never '
      'holds', () async {
    final world = _World(
      limits: const LaunchLimits(holdBackgroundAbovePercent: 80),
    );
    world.percents['claude@windows'] = 92;
    world.percents['codex@windows'] = null;
    final held = world.gate.acquire(
      world.claim('bg', priority: LaunchPriority.background),
    );
    expect(
      (held as LaunchWaiting).reason,
      'Waiting: claude@windows is at 92% of its 5-hour window, over the 80% '
      'hold for background work',
    );
    expect(
      world.gate.acquire(
        world.claim(
          'unknown',
          priority: LaunchPriority.background,
          account: 'codex@windows',
        ),
      ),
      isA<LaunchGranted>(),
    );
    expect(world.gate.acquire(world.claim('person')), isA<LaunchGranted>());
    world.percents['claude@windows'] = 40;
    world.gate.pump();
    await _settle();
    expect(world.started, ['bg']);
  });

  test('changes are told when the snapshot reads differently', () async {
    final world = _World(limits: const LaunchLimits(global: 1));
    var told = 0;
    final sub = world.gate.changes.listen((_) => told++);
    world.run(world.claim('one'));
    world.gate.acquire(world.claim('two'));
    await _settle();
    expect(told, greaterThan(0));
    final before = told;
    world.gate.pump();
    await _settle();
    expect(told, before);
    await sub.cancel();
  });
}
