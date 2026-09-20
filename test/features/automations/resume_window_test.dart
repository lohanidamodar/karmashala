import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/domain/resume_window.dart';
import 'package:karmashala/src/features/automations/domain/scheduled_resume.dart';

void main() {
  final now = DateTime.utc(2026, 9, 17, 12);

  UsageWindow window(String label, double? percent, Duration? resetsIn) =>
      UsageWindow(
        label: label,
        percent: percent,
        resetsAt: resetsIn == null ? null : now.add(resetsIn),
      );

  AgentUsage reading(List<UsageWindow> windows, {DateTime? fetchedAt}) =>
      AgentUsage(windows: windows, fetchedAt: fetchedAt ?? now);

  group('blockingWindow', () {
    test('the spent window wins over a nearer reset', () {
      final picked = blockingWindow([
        window('5-hour', 40, const Duration(hours: 1)),
        window('7-day', 100, const Duration(days: 3)),
      ], now: now);
      expect(picked?.window.label, '7-day');
      expect(picked?.reason, BlockingWindowReason.spent);
    });

    test('two spent windows wait for the later reset', () {
      final picked = blockingWindow([
        window('5-hour', 100, const Duration(hours: 1)),
        window('7-day', 100, const Duration(days: 2)),
      ], now: now);
      expect(picked?.window.label, '7-day');
    });

    test('the window the agent named beats one that is merely near', () {
      final picked = blockingWindow(
        [
          window('5-hour', 60, const Duration(hours: 2)),
          window('7-day', 97, const Duration(days: 2)),
        ],
        now: now,
        namedLabel: '5-hour',
      );
      expect(picked?.window.label, '5-hour');
      expect(picked?.reason, BlockingWindowReason.named);
    });

    test('near the limit beats the soonest reset', () {
      final picked = blockingWindow([
        window('5-hour', 20, const Duration(hours: 1)),
        window('7-day', 96, const Duration(days: 2)),
      ], now: now);
      expect(picked?.window.label, '7-day');
      expect(picked?.reason, BlockingWindowReason.nearLimit);
    });

    test('with nothing blocking, the soonest reset', () {
      final picked = blockingWindow([
        window('7-day', 10, const Duration(days: 2)),
        window('5-hour', 20, const Duration(hours: 1)),
      ], now: now);
      expect(picked?.window.label, '5-hour');
      expect(picked?.reason, BlockingWindowReason.soonestReset);
    });

    test('a window with no reset to come cannot be waited on', () {
      expect(
        blockingWindow([
          window('Extra usage', 100, null),
          window('5-hour', 100, const Duration(minutes: -1)),
        ], now: now),
        isNull,
      );
    });
  });

  group('checkReset', () {
    test('nothing spent is a reset', () {
      expect(
        checkReset(
          reading([window('5-hour', 3, const Duration(hours: 5))]),
          now: now,
        ),
        isA<ResetConfirmed>(),
      );
    });

    test('still spent names the latest reset to come', () {
      final check = checkReset(
        reading([
          window('5-hour', 100, const Duration(hours: 1)),
          window('7-day', 100, const Duration(days: 1)),
        ]),
        now: now,
      );
      expect(check, isA<StillLimited>());
      expect((check as StillLimited).label, '7-day');
      expect(check.until, now.add(const Duration(days: 1)));
    });

    test('a reading taken before the reset it shows says nothing', () {
      final check = checkReset(
        reading([
          window('5-hour', 100, const Duration(minutes: -1)),
        ], fetchedAt: now.subtract(const Duration(minutes: 2))),
        now: now,
      );
      expect(check, isA<ReadingPredatesReset>());
    });

    test('spent after its own reset is still limited, with no reset named', () {
      final check = checkReset(
        reading([window('5-hour', 100, const Duration(minutes: -1))]),
        now: now,
      );
      expect(check, isA<StillLimited>());
      expect((check as StillLimited).until, isNull);
    });
  });

  group('nextResumeAttempt', () {
    test('aims at the new reset plus the margin', () {
      final until = now.add(const Duration(hours: 1));
      expect(
        nextResumeAttempt(attempts: 1, now: now, until: until),
        until.add(kResumeResetMargin),
      );
    });

    test('with no reset named it backs off, doubling', () {
      expect(
        nextResumeAttempt(attempts: 1, now: now),
        now.add(kResumeRetryBase),
      );
      expect(
        nextResumeAttempt(attempts: 3, now: now),
        now.add(kResumeRetryBase * 4),
      );
    });

    test('the doubling stops at the ceiling rather than at a day', () {
      expect(
        nextResumeAttempt(attempts: 20, now: now),
        now.add(kResumeRetryCeiling),
      );
    });

    test('never gives up, however many attempts have been made', () {
      // A limit reached again is the case a resume-on-reset was armed for.
      final until = now.add(const Duration(hours: 5));
      for (final attempts in [1, 5, 40, 400]) {
        expect(
          nextResumeAttempt(attempts: attempts, now: now, until: until),
          until.add(kResumeResetMargin),
        );
        expect(
          nextResumeAttempt(attempts: attempts, now: now),
          isA<DateTime>().having((at) => at.isAfter(now), 'is later', isTrue),
        );
      }
    });
  });

  group('windowRolledOverEarly', () {
    ScheduledResume waitingOn(Duration resetsIn) => ScheduledResume(
      id: 'r1',
      sessionId: 's1',
      windowLabel: '5-hour',
      resetsAt: now.add(resetsIn),
      fireAt: now.add(resetsIn + kResumeResetMargin),
      state: ScheduledResumeState.pending,
      scheduledAt: now,
    );

    test('a fresh window that is not spent has rolled over', () {
      expect(
        windowRolledOverEarly(
          waitingOn(const Duration(hours: 1)),
          reading([window('5-hour', 0, const Duration(hours: 5))]),
          now: now,
        ),
        isTrue,
      );
    });

    test('the same reset, not yet spent, has not', () {
      expect(
        windowRolledOverEarly(
          waitingOn(const Duration(hours: 1)),
          reading([window('5-hour', 96, const Duration(minutes: 61))]),
          now: now,
        ),
        isFalse,
      );
    });

    test('a later reset that is still spent has not', () {
      expect(
        windowRolledOverEarly(
          waitingOn(const Duration(hours: 1)),
          reading([window('5-hour', 100, const Duration(hours: 3))]),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
