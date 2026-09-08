import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/domain/cron_schedule.dart';

/// The five-field expression, and the two questions the scheduler asks it.
///
/// Times are **local**, because that is what a person writing "03:00 nightly"
/// means, so every expectation here is built with `DateTime(...)` rather than
/// `DateTime.utc(...)`.
void main() {
  DateTime at(int y, int m, int d, [int h = 0, int min = 0]) =>
      DateTime(y, m, d, h, min);

  group('what it accepts', () {
    test('a daily expression finds the next 03:00', () {
      final cron = CronSchedule.parse('0 3 * * *')!;
      expect(cron.nextAfter(at(2026, 9, 8, 17)), at(2026, 9, 9, 3));
      expect(cron.nextAfter(at(2026, 9, 9, 2, 59)), at(2026, 9, 9, 3));
      // Strictly after: standing exactly on an occurrence yields the next one.
      expect(cron.nextAfter(at(2026, 9, 9, 3)), at(2026, 9, 10, 3));
    });

    test('a step, a range and a list all parse', () {
      expect(CronSchedule.parse('*/15 * * * *')!.nextAfter(at(2026, 9, 9, 1, 2)),
          at(2026, 9, 9, 1, 15));
      expect(CronSchedule.parse('0 9-17 * * *')!.nextAfter(at(2026, 9, 9, 8)),
          at(2026, 9, 9, 9));
      expect(CronSchedule.parse('0 6,18 * * *')!.nextAfter(at(2026, 9, 9, 7)),
          at(2026, 9, 9, 18));
    });

    test('weekdays, with Sunday spelled either way', () {
      // 2026-09-09 is a Wednesday; the next Monday is the 14th.
      final weekdays = CronSchedule.parse('0 3 * * 1-5')!;
      expect(weekdays.nextAfter(at(2026, 9, 11, 4)), at(2026, 9, 14, 3));
      expect(
        CronSchedule.parse('0 3 * * 0')!.nextAfter(at(2026, 9, 9)),
        CronSchedule.parse('0 3 * * 7')!.nextAfter(at(2026, 9, 9)),
      );
    });

    test('day-of-month and day-of-week together are an OR, as cron has it', () {
      // The 1st **or** any Monday.
      final cron = CronSchedule.parse('0 3 1 * 1')!;
      expect(cron.nextAfter(at(2026, 9, 9)), at(2026, 9, 14, 3)); // Monday
      expect(cron.nextAfter(at(2026, 9, 15)), at(2026, 9, 21, 3)); // Monday
      expect(cron.nextAfter(at(2026, 9, 29)), at(2026, 10, 1, 3)); // the 1st
    });
  });

  group('what it refuses rather than guesses at', () {
    test('the dialects it does not have are refused by name', () {
      for (final expression in const [
        '@daily',
        '0 3 * *',
        '0 3 * * * *',
        '0 3 L * *',
        '0 3 * * MON',
        '61 3 * * *',
        '0 25 * * *',
        '0 3 */0 * *',
      ]) {
        expect(
          CronSchedule.parse(expression),
          isNull,
          reason: '"$expression" must not half-parse',
        );
        expect(cronRefusal(expression), isNotNull);
      }
    });

    test('an empty schedule says what one looks like', () {
      expect(cronRefusal('  '), contains('Five fields'));
      expect(cronRefusal('  '), contains('0 3 * * *'));
    });

    test('an expression that never comes round is refused with that reason', () {
      // The 30th of February parses and never happens.
      expect(CronSchedule.parse('0 0 30 2 *'), isNotNull);
      expect(cronRefusal('0 0 30 2 *'), contains('never comes round'));
    });

    test('one it can read is not refused', () {
      expect(cronRefusal('0 3 * * *'), isNull);
      expect(cronRefusal('*/5 * * * 1-5'), isNull);
    });
  });

  group('looking backwards', () {
    test('the newest occurrence at or before a moment', () {
      final cron = CronSchedule.parse('0 3 * * *')!;
      expect(cron.previousAtOrBefore(at(2026, 9, 9, 9)), at(2026, 9, 9, 3));
      // At or before includes standing exactly on one.
      expect(cron.previousAtOrBefore(at(2026, 9, 9, 3)), at(2026, 9, 9, 3));
      expect(cron.previousAtOrBefore(at(2026, 9, 9, 2)), at(2026, 9, 8, 3));
    });

    test('a leap-day schedule is found in both directions', () {
      final cron = CronSchedule.parse('0 0 29 2 *')!;
      expect(cron.nextAfter(at(2026, 3, 1)), at(2028, 2, 29));
      expect(cron.previousAtOrBefore(at(2026, 3, 1)), at(2024, 2, 29));
    });
  });

  group('counting what was due', () {
    test('an empty window yields nothing', () {
      final cron = CronSchedule.parse('0 3 * * *')!;
      expect(cron.occurrencesBetween(at(2026, 9, 9, 4), at(2026, 9, 9, 5)), isEmpty);
      expect(cron.occurrencesBetween(at(2026, 9, 9, 5), at(2026, 9, 9, 4)), isEmpty);
    });

    test('a night of downtime counts every occurrence, ascending', () {
      final cron = CronSchedule.parse('0 * * * *')!;
      final due = cron.occurrencesBetween(at(2026, 9, 8, 17), at(2026, 9, 9, 9));
      expect(due, hasLength(16));
      expect(due.first, at(2026, 9, 8, 18));
      expect(due.last, at(2026, 9, 9, 9));
    });

    test('the count is capped, and the newest is still found past the cap', () {
      final cron = CronSchedule.parse('* * * * *')!;
      final due = cron.occurrencesBetween(
        at(2026, 9, 1),
        at(2026, 9, 9),
        limit: 10,
      );
      expect(due, hasLength(10));
      // The cap bounds the counting, never the answer to "which was newest".
      expect(cron.previousAtOrBefore(at(2026, 9, 9)), at(2026, 9, 9));
    });
  });
}
