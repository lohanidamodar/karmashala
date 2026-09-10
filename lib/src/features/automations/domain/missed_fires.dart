/// What to do about occurrences that came round while the app was down: one
/// catch-up for the newest, inside a grace window; the rest become `missed`.
library;

import 'automation.dart';
import 'cron_schedule.dart';

/// How late an occurrence may be and still be run on wake. One constant for
/// both schedule kinds, so a cron and a one-shot cannot disagree.
const Duration kMissedFireGrace = Duration(minutes: 15);

/// Ceiling on how many occurrences are counted — a minutely automation over a
/// fortnight is 20,000 iterations; past this the reason says "at least N".
const int kMaxCountedMisses = 500;

/// What a boot should do about one automation.
sealed class MissedFireDecision {
  const MissedFireDecision();
}

/// Nothing was due while we were away.
class NoMissedFires extends MissedFireDecision {
  const NoMissedFires();
}

/// The newest missed occurrence is fresh enough to still run now.
class CatchUpMissedFire extends MissedFireDecision {
  const CatchUpMissedFire({
    required this.scheduledFor,
    required this.missedCount,
    required this.capped,
    this.older,
  });

  final DateTime scheduledFor;

  /// How many occurrences were missed in all, this one included.
  final int missedCount;

  /// True when [missedCount] hit [kMaxCountedMisses] and is a floor.
  final bool capped;

  /// The occurrences before this one, which are recorded as missed rather than
  /// run. Null when this was the only one.
  final MissedFires? older;
}

/// Too late to run. Recorded so the miss is visible instead of silent.
class MissedFires extends MissedFireDecision {
  const MissedFires({
    required this.scheduledFor,
    required this.missedCount,
    required this.capped,
    required this.lateBy,
  });

  /// The newest of them — what the row is dated by.
  final DateTime scheduledFor;

  final int missedCount;
  final bool capped;

  /// How late [scheduledFor] is by now. Zero when the row is about older
  /// occurrences beside a catch-up.
  final Duration lateBy;
}

/// What to do about [automation] on wake. [since] is floored at when it was
/// armed, or a new automation would "discover" every occurrence since 1970.
MissedFireDecision missedFireDecision({
  required AutomationSchedule schedule,
  required DateTime since,
  required DateTime now,
  Duration grace = kMissedFireGrace,
}) {
  if (!since.isBefore(now)) return const NoMissedFires();

  if (schedule.isOnce) {
    final at = schedule.firesAt!;
    // A one-shot before the floor was already dealt with; one after `now` is
    // not missed at all, it is simply not due.
    if (!at.isAfter(since) || at.isAfter(now)) return const NoMissedFires();
    final lateBy = now.difference(at);
    return lateBy <= grace
        ? CatchUpMissedFire(scheduledFor: at, missedCount: 1, capped: false)
        : MissedFires(
            scheduledFor: at,
            missedCount: 1,
            capped: false,
            lateBy: lateBy,
          );
  }

  final cron = CronSchedule.parse(schedule.cron!);
  if (cron == null) return const NoMissedFires();

  final occurrences = cron.occurrencesBetween(
    since,
    now,
    limit: kMaxCountedMisses,
  );
  if (occurrences.isEmpty) return const NoMissedFires();

  // Asked of the schedule rather than taken from the list, so the newest is
  // right even when the count was capped.
  final newest = cron.previousAtOrBefore(now);
  if (newest == null || !newest.isAfter(since)) return const NoMissedFires();

  final missedCount = occurrences.length;
  final capped = missedCount >= kMaxCountedMisses;
  final lateBy = now.difference(newest);

  if (lateBy <= grace) {
    return CatchUpMissedFire(
      scheduledFor: newest,
      missedCount: missedCount,
      capped: capped,
      // Everything older than the one being run is still a miss and is recorded
      // as one, rather than folded into the catch-up's note.
      older: missedCount > 1
          ? MissedFires(
              scheduledFor: occurrences[missedCount - 2],
              missedCount: missedCount - 1,
              capped: capped,
              lateBy: Duration.zero,
            )
          : null,
    );
  }
  return MissedFires(
    scheduledFor: newest,
    missedCount: missedCount,
    capped: capped,
    lateBy: lateBy,
  );
}

/// The reason a `missed` row carries. **Never empty** — a miss with no reason
/// is the silence this whole rule exists to remove.
String missedFireReason(MissedFires missed) {
  final count = _countLabel(missed.missedCount, missed.capped);
  if (missed.lateBy == Duration.zero) {
    return 'Karmashala was not running when these were due — $count were '
        'missed. Only the most recent occurrence is ever caught up, and it was '
        'run instead of these.';
  }
  return 'Karmashala was not running when this was due — $count were missed, '
      'the most recent ${_agoLabel(missed.lateBy)} ago. Only a fire within '
      '${kMissedFireGrace.inMinutes} minutes is caught up on wake; run it now '
      'if you still want it.';
}

/// The note a catch-up run carries, so the audit says why it was off schedule.
String caughtUpReason(CatchUpMissedFire decision) {
  final count = _countLabel(decision.missedCount, decision.capped);
  return 'Karmashala was not running when this was due — $count were missed. '
      'The most recent one was still inside the '
      '${kMissedFireGrace.inMinutes}-minute catch-up window and is running now.';
}

String _countLabel(int count, bool capped) {
  if (capped) return 'at least $count runs';
  return count == 1 ? '1 run' : '$count runs';
}

String _agoLabel(Duration late) {
  final minutes = late.inMinutes;
  if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';
  final hours = late.inHours;
  if (hours < 48) return '$hours hour${hours == 1 ? '' : 's'}';
  final days = late.inDays;
  return '$days day${days == 1 ? '' : 's'}';
}
