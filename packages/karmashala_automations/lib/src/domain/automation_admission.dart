import 'automation.dart';
import 'automation_run.dart';

/// Runs an automation may start in any hour unless its owner says otherwise.
const int kDefaultRunsPerHour = 30;

/// How many triggers may wait behind an automation's run by default.
const int kDefaultQueueLimit = 3;

/// What a trigger does when its automation already has a run going where it
/// would run.
enum AutomationOverlap {
  /// It waits its turn, up to the automation's queue limit.
  queue,

  /// It folds into the one already waiting, which runs once for both.
  merge;

  static AutomationOverlap fromName(String? name) => values.firstWhere(
    (o) => o.name == name,
    orElse: () => AutomationOverlap.queue,
  );

  String get label => switch (this) {
    AutomationOverlap.queue => 'Queue it',
    AutomationOverlap.merge => 'Merge into the waiting one',
  };
}

/// Where a run works, for "one at a time": a pull request's branch, or the
/// automation's own place (empty).
String runLane(AutomationRun run) => run.variables['github.pr.branch'] ?? '';

/// Why [automation] may start no more runs this hour, or null. Missed runs
/// and Run now do not count.
String? hourlyRefusal(
  Automation automation, {
  required Iterable<AutomationRun> recent,
  required DateTime now,
}) {
  final perHour = automation.runsPerHour;
  if (perHour <= 0) return null;
  final hourAgo = now.subtract(const Duration(hours: 1));
  final started = recent
      .where(
        (run) =>
            run.firedAt.isAfter(hourAgo) &&
            run.state != AutomationRunState.missed &&
            run.startedBy != AutomationRunCause.runNow,
      )
      .length;
  if (started < perHour) return null;
  return 'Not started: "${automation.name}" has started $started runs in the '
      'last hour, and it allows $perHour.';
}

/// How many of an automation's newest runs to read to judge its hour.
int recentRunsToRead(Automation automation) =>
    ((automation.runsPerHour + automation.queueLimit) * 3 + 20).clamp(50, 2000);

/// What a new trigger of an automation becomes.
sealed class Admission {
  const Admission();
}

final class AdmitStart extends Admission {
  const AdmitStart();
}

/// It waits behind the automation's own run in the same place.
final class AdmitQueue extends Admission {
  const AdmitQueue(this.reason);

  final String reason;
}

/// It is not started, and its row says why.
final class AdmitRefuse extends Admission {
  const AdmitRefuse(this.reason);

  final String reason;
}

/// Whether [automation] may take one more run in [lane] now: under its runs
/// an hour, and one at a time in each place, with later triggers queued (at
/// most its limit) or merged into the one waiting. [recent] is its runs,
/// newest first, at least the last hour's.
Admission admitRun(
  Automation automation, {
  required String lane,
  required Iterable<AutomationRun> recent,
  required DateTime now,
  bool byPerson = false,
}) {
  if (!byPerson) {
    if (hourlyRefusal(automation, recent: recent, now: now) case final why?) {
      return AdmitRefuse(why);
    }
  }
  final here = [
    for (final run in recent)
      if (run.state.isLive && runLane(run) == lane) run,
  ];
  if (here.isEmpty) return const AdmitStart();
  final waiting = here.where((r) => r.state == AutomationRunState.queued);
  final place = lane.isEmpty ? 'its checkout' : 'branch $lane';
  switch (automation.overlap) {
    case AutomationOverlap.merge:
      if (waiting.isNotEmpty) {
        return AdmitRefuse(
          'Merged into the run already waiting in $place, which will run '
          'once for both.',
        );
      }
      return AdmitQueue(
        'Waiting for "${automation.name}"\'s run in $place to finish; later '
        'triggers merge into this one.',
      );
    case AutomationOverlap.queue:
      if (waiting.length >= automation.queueLimit) {
        return AdmitRefuse(
          'Not started: ${waiting.length} runs of "${automation.name}" are '
          'already waiting in $place, its limit.',
        );
      }
      return AdmitQueue(
        'Waiting for "${automation.name}"\'s run in $place to finish. One '
        'run at a time in each place.',
      );
  }
}
