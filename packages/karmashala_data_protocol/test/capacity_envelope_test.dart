import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// Concurrency limits, their waits and the requests about them cross the
/// wire whole.
void main() {
  Object? roundTrip(Object? json) => jsonDecode(jsonEncode(json));
  DataRequest<Object?> across(DataRequest<Object?> request) =>
      DataRequest.fromJson(
        request.kind,
        (roundTrip(request.argumentsToJson())! as Map).cast<String, Object?>(),
      );

  const limits = LaunchLimits(
    global: 4,
    machines: {'wsl-arch': 2},
    accounts: {'claudeCode@windows': 3},
    projects: {'p1': 1},
    pauseBackground: true,
    holdBackgroundAbovePercent: 80,
  );
  final snapshot = CapacitySnapshot(
    limits: limits,
    running: 2,
    scopes: const [
      CapacityScopeUse(
        scope: CapacityScope.machine,
        key: 'wsl-arch',
        label: 'WSL · archlinux',
        used: 2,
        limit: 2,
        holders: ['X', 'Y'],
      ),
    ],
    waiters: [
      LaunchWaiter(
        ticketId: 't1',
        label: 'Z',
        sessionId: 's3',
        priority: LaunchPriority.background,
        place: 1,
        reason: 'Waiting for a slot: 2 of 2 on WSL · archlinux are busy (X, Y)',
        enqueuedAt: DateTime.utc(2026, 10, 9, 12),
        personStarted: true,
      ),
    ],
  );

  test('limits read back as written; nonsense is no limit', () {
    expect(LaunchLimits.fromJson(roundTrip(limits.toJson())), limits);
    expect(
      LaunchLimits.fromJson({
        'global': 0,
        'machines': {'w': -1, 'x': 'two'},
        'holdBackgroundAbovePercent': 140,
      }),
      LaunchLimits.none,
    );
    expect(LaunchLimits.none.hasLimits, isFalse);
  });

  test('a snapshot crosses whole', () {
    final back = CapacitySnapshot.fromJson(
      (roundTrip(snapshot.toJson())! as Map).cast<String, Object?>(),
    );
    expect(back.limits, limits);
    expect(back.running, 2);
    expect(back.scopes.single.holders, ['X', 'Y']);
    expect(back.scopes.single.isFull, isTrue);
    final waiter = back.waiterFor('s3')!;
    expect(waiter.priority, LaunchPriority.background);
    expect(waiter.reason, snapshot.waiters.single.reason);
    expect(waiter.enqueuedAt, DateTime.utc(2026, 10, 9, 12));
    expect(waiter.personStarted, isTrue);
  });

  test('the change carries the snapshot', () {
    final change = DataChange.fromJson(
      (roundTrip(CapacityChanged(snapshot).toJson())! as Map)
          .cast<String, Object?>(),
    );
    expect(change, isA<CapacityChanged>());
    expect((change! as CapacityChanged).capacity.waiters.single.ticketId, 't1');
  });

  test('the requests cross', () {
    expect(across(const SessionCapacityRead()), isA<SessionCapacityRead>());
    expect(
      (across(const SessionWaitStartAnyway('t1')) as SessionWaitStartAnyway)
          .ticketId,
      't1',
    );
    expect(
      (across(const SessionWaitCancel('t1')) as SessionWaitCancel).ticketId,
      't1',
    );
    const read = SessionCapacityRead();
    expect(
      read.resultFromJson(roundTrip(read.resultToJson(snapshot))).running,
      2,
    );
  });

  test('a start that waits says so', () {
    final started = SessionStarted(
      session: Session(
        id: 's3',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Z',
        useWorktree: false,
        status: SessionStatus.created,
        createdAt: DateTime.utc(2026, 10, 9),
      ),
      wait: const SessionWait(ticketId: 't1', reason: 'full', place: 2),
    );
    final back = SessionStarted.fromJson(
      (roundTrip(started.toJson())! as Map).cast<String, Object?>(),
    );
    expect(back.waiting, isTrue);
    expect(back.wait!.place, 2);
    expect(
      SessionStarted.fromJson(
        (roundTrip(SessionStarted(session: started.session).toJson())! as Map)
            .cast<String, Object?>(),
      ).waiting,
      isFalse,
    );
  });
}
