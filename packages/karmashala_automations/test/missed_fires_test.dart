import 'package:test/test.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/schedules.dart';

/// The four cases a closed laptop produces, and the rule that "next run in 18
/// hours" is never the answer to any of them.
void main() {
  DateTime at(int y, int m, int d, [int h = 0, int min = 0]) =>
      DateTime(y, m, d, h, min);

  const nightly = AutomationSchedule.cron('0 3 * * *');
  const hourly = AutomationSchedule.cron('0 * * * *');

  MissedFireDecision decide({
    AutomationSchedule schedule = nightly,
    required DateTime since,
    required DateTime now,
  }) => missedFireDecision(schedule: schedule, since: since, now: now);

  group('a recurring automation', () {
    test('no miss: nothing was due while we were away', () {
      final decision = decide(since: at(2026, 9, 9, 3), now: at(2026, 9, 9, 9));
      expect(decision, isA<NoMissedFires>());
    });

    test('one miss inside the grace window is caught up, once', () {
      final decision = decide(
        since: at(2026, 9, 9, 2, 50),
        now: at(2026, 9, 9, 3, 10),
      );
      final catchUp = decision as CatchUpMissedFire;
      expect(catchUp.scheduledFor, at(2026, 9, 9, 3));
      expect(catchUp.missedCount, 1);
      expect(catchUp.older, isNull, reason: 'there is nothing older to record');
      expect(caughtUpReason(catchUp), contains('is running now'));
    });

    test('one miss outside it becomes a recorded miss, with its reason', () {
      final decision = decide(
        since: at(2026, 9, 9, 2, 50),
        now: at(2026, 9, 9, 9),
      );
      final missed = decision as MissedFires;
      expect(missed.scheduledFor, at(2026, 9, 9, 3));
      expect(missed.missedCount, 1);
      expect(missed.lateBy, const Duration(hours: 6));
      final reason = missedFireReason(missed);
      expect(reason, contains('1 run'));
      expect(reason, contains('6 hours ago'));
      expect(reason, contains('run it now if you still want it'));
    });

    test(
      'several: the newest is caught up and everything older is one missed row',
      () {
        // Shut at 17:00, opened at 09:05 — sixteen hourly occurrences, the last
        // of them five minutes ago.
        final decision = decide(
          schedule: hourly,
          since: at(2026, 9, 8, 17),
          now: at(2026, 9, 9, 9, 5),
        );
        final catchUp = decision as CatchUpMissedFire;
        expect(catchUp.scheduledFor, at(2026, 9, 9, 9));
        expect(catchUp.missedCount, 16);
        expect(caughtUpReason(catchUp), contains('16 runs'));
        // At most one catch-up run; the other fifteen are visible as a miss
        // rather than replayed.
        final older = catchUp.older!;
        expect(older.missedCount, 15);
        expect(older.scheduledFor, at(2026, 9, 9, 8));
        expect(missedFireReason(older), contains('15 runs'));
        expect(
          missedFireReason(older),
          contains('Only the most recent occurrence is ever caught up'),
        );
      },
    );

    test('several, all too old: one missed row dated by the newest', () {
      final decision = decide(
        schedule: hourly,
        since: at(2026, 9, 8, 17),
        now: at(2026, 9, 9, 9, 45),
      );
      final missed = decision as MissedFires;
      expect(missed.scheduledFor, at(2026, 9, 9, 9));
      expect(missed.missedCount, 16);
      expect(missed.lateBy, const Duration(minutes: 45));
      expect(missedFireReason(missed), contains('45 minutes ago'));
    });

    test('a year of hourly runs is counted at a floor, not exactly', () {
      final decision = decide(
        schedule: hourly,
        since: at(2025, 9, 9),
        now: at(2026, 9, 9, 9, 45),
      );
      final missed = decision as MissedFires;
      expect(missed.capped, isTrue);
      expect(missed.missedCount, kMaxCountedMisses);
      expect(missedFireReason(missed), contains('at least 500 runs'));
      // The cap bounds the counting; the newest occurrence is still exact,
      // because it is asked of the schedule rather than read off the list.
      expect(missed.scheduledFor, at(2026, 9, 9, 9));
    });

    test(
      'a minutely schedule always has a fresh occurrence, so it catches up',
      () {
        final decision = decide(
          schedule: const AutomationSchedule.cron('* * * * *'),
          since: at(2026, 8, 26),
          now: at(2026, 9, 9, 9),
        );
        final catchUp = decision as CatchUpMissedFire;
        expect(catchUp.scheduledFor, at(2026, 9, 9, 9));
        expect(catchUp.capped, isTrue);
        // One run, and the whole fortnight behind it recorded as missed.
        expect(catchUp.older!.missedCount, kMaxCountedMisses - 1);
      },
    );

    test('occurrences before the floor were never ours to claim', () {
      // Armed five minutes ago; a daily 03:00 has run for years and none of it
      // belongs to this automation.
      final decision = decide(
        since: at(2026, 9, 9, 8, 55),
        now: at(2026, 9, 9, 9),
      );
      expect(decision, isA<NoMissedFires>());
    });

    test('an expression this build cannot read claims nothing', () {
      final decision = decide(
        schedule: const AutomationSchedule.cron('@daily'),
        since: at(2020, 1, 1),
        now: at(2026, 9, 9),
      );
      expect(decision, isA<NoMissedFires>());
    });
  });

  group('a one-shot', () {
    test('one still in the future is not missed, it is simply not due', () {
      final decision = decide(
        schedule: AutomationSchedule.once(at(2026, 9, 10, 3)),
        since: at(2026, 9, 9),
        now: at(2026, 9, 9, 9),
      );
      expect(decision, isA<NoMissedFires>());
    });

    test('one just missed is caught up', () {
      final decision = decide(
        schedule: AutomationSchedule.once(at(2026, 9, 9, 8, 55)),
        since: at(2026, 9, 9),
        now: at(2026, 9, 9, 9),
      );
      expect(
        (decision as CatchUpMissedFire).scheduledFor,
        at(2026, 9, 9, 8, 55),
      );
    });

    test('one long past is a miss, not a fire tomorrow', () {
      final decision = decide(
        schedule: AutomationSchedule.once(at(2026, 9, 9, 3)),
        since: at(2026, 9, 9),
        now: at(2026, 9, 9, 9),
      );
      final missed = decision as MissedFires;
      expect(missed.scheduledFor, at(2026, 9, 9, 3));
      expect(missedFireReason(missed), isNotEmpty);
    });
  });

  group('latency is not downtime', () {
    final tenMinutes = AutomationSchedule.every(const Duration(minutes: 10));

    test('an occurrence the app was up for runs, though the tick is late', () {
      final decision = missedFireDecision(
        schedule: tenMinutes,
        since: at(2026, 9, 9, 17),
        now: at(2026, 9, 9, 17, 10).add(const Duration(milliseconds: 40)),
        grace: kSchedulerLatencyTolerance,
        availableSince: at(2026, 9, 9, 17),
      );
      expect(
        (decision as CatchUpMissedFire).scheduledFor,
        at(2026, 9, 9, 17, 10),
      );
    });

    test('one due before the app was up is missed, however fresh', () {
      final decision = missedFireDecision(
        schedule: hourly,
        since: at(2026, 9, 9, 8),
        now: DateTime(2026, 9, 9, 9, 0, 30),
        grace: kSchedulerLatencyTolerance,
        availableSince: DateTime(2026, 9, 9, 9, 0, 20),
      );
      final missed = decision as MissedFires;
      expect(missed.scheduledFor, at(2026, 9, 9, 9));
      expect(missed.missedCount, 1);
    });

    test('a tick later than the tolerance is downtime — a suspend', () {
      final decision = missedFireDecision(
        schedule: AutomationSchedule.once(at(2026, 9, 9, 3)),
        since: at(2026, 9, 9),
        now: at(2026, 9, 9, 3, 2),
        grace: kSchedulerLatencyTolerance,
        availableSince: at(2026, 9, 9),
      );
      expect(decision, isA<MissedFires>());
    });
  });
}
