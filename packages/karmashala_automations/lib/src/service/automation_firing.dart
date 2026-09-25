import '../domain/automation.dart';
import '../domain/automation_run.dart';
import '../domain/scheduled_resume.dart';

/// What happens when an occurrence comes due. It must always record a run for
/// the occurrence, even a refusal, or the fire would repeat on every tick.
abstract interface class AutomationFiring {
  /// Starts [automation] for the occurrence due at [scheduledFor]. [queued] is
  /// the waiting row this fire *is*, updated so one fire is not reported twice.
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note,
    AutomationRun? queued,
  });
}

/// What happens when a scheduled resume comes due. Every call must leave the
/// row out of `pending`, or the same fire would repeat on every tick.
abstract interface class ScheduledResumeFiring {
  Future<void> fire(ScheduledResume resume, {String note});
}
