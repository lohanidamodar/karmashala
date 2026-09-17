import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../data/automation_dao.dart';
import '../data/scheduled_resume_dao.dart';
import '../domain/automation.dart';
import '../domain/automation_run.dart';
import '../domain/cron_schedule.dart';
import '../domain/missed_fires.dart';
import '../domain/scheduled_resume.dart';
import 'automation_providers.dart';
import 'automation_runner.dart';
import 'automation_timer.dart';
import 'scheduled_resume_providers.dart';
import 'scheduled_resume_runner.dart';

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

/// The real one is [AutomationRunner]. Overridden by tests with a recorder.
final automationFiringProvider = Provider<AutomationFiring>(
  AutomationRunner.new,
);

/// Longest a single timer is armed for, after which it re-arms — not a poll:
/// it exists so a schedule six months out is not one `Timer` across a suspend.
const Duration kMaxTimerDelay = Duration(hours: 24);

/// One armed timer for the next occurrence across every automation and every
/// scheduled resume; nothing polls (§19). Must be watched, or Riverpod 3 pauses it and it arms nothing.
class AutomationScheduler extends Notifier<int> {
  /// Whether the one boot sweep this process gets has run. Kept on the
  /// notifier rather than in [state], because [build] re-runs on every change.
  bool _reconciled = false;

  @override
  int build() {
    final revision = ref.watch(automationsRevisionProvider);
    final timer = ref.watch(automationTimerProvider);
    ref.onDispose(timer.cancel);

    arm();

    // Arming covers fires from now on; anything due while the process was down
    // is reconciled separately, deferred so every automation is armed first.
    if (!_reconciled) {
      _reconciled = true;
      unawaited(Future<void>.microtask(reconcile));
    }
    return revision;
  }

  AutomationDao get _dao => ref.read(automationDaoProvider);
  ScheduledResumeDao get _resumes => ref.read(scheduledResumeDaoProvider);
  DateTime get _now => ref.read(clockProvider).nowUtc();
  String _newId() => ref.read(idGeneratorProvider).newId();

  /// The soonest occurrence across every enabled automation, or null when
  /// nothing is due ever again.
  DateTime? nextOccurrence(DateTime after) {
    DateTime? soonest;
    for (final automation in _dao.enabled()) {
      final next = _nextFor(automation, after);
      if (next == null) continue;
      if (soonest == null || next.isBefore(soonest)) soonest = next;
    }
    for (final resume in _resumes.inState(ScheduledResumeState.pending)) {
      // One already due is next right now, not never.
      final next = resume.fireAt.isAfter(after) ? resume.fireAt : after;
      if (soonest == null || next.isBefore(soonest)) soonest = next;
    }
    return soonest;
  }

  DateTime? _nextFor(Automation automation, DateTime after) {
    final schedule = automation.schedule;
    if (schedule.isOnce) {
      final at = schedule.firesAt!;
      return at.isAfter(after) ? at : null;
    }
    return CronSchedule.parse(schedule.cron!)?.nextAfter(after);
  }

  /// Arms the one timer for the next occurrence, replacing whatever was armed.
  void arm() {
    final timer = ref.read(automationTimerProvider);
    final now = _now;
    final next = nextOccurrence(now);
    if (next == null) {
      timer.cancel();
      return;
    }
    final delay = next.difference(now);
    timer.arm(delay > kMaxTimerDelay ? kMaxTimerDelay : delay, () {
      unawaited(_onTimer());
    });
  }

  Future<void> _onTimer() async {
    await reconcile();
    // A tick that found nothing writes nothing, so no rebuild re-arms it — and
    // a timer that fired and did not re-arm has quietly stopped.
    arm();
  }

  /// Accounts for every occurrence due since each automation was last watched.
  /// The floor is never before arming, or a new one would discover the epoch.
  Future<void> reconcile() async {
    final now = _now;
    var changed = false;
    for (final automation in _dao.enabled()) {
      final decision = missedFireDecision(
        schedule: automation.schedule,
        since: _floorFor(automation),
        now: now,
      );
      switch (decision) {
        case NoMissedFires():
          continue;
        case MissedFires():
          _recordMissed(automation, decision, now);
          changed = true;
        case CatchUpMissedFire():
          // At most one catch-up run; everything older is a miss with a reason.
          final older = decision.older;
          if (older != null) _recordMissed(automation, older, now);
          await _fireOrQueue(
            automation,
            decision.scheduledFor,
            note: decision.missedCount > 1 ? caughtUpReason(decision) : '',
          );
          changed = true;
      }
    }
    if (await _reconcileResumes(now)) changed = true;
    if (changed) ref.read(automationsRevisionProvider.notifier).bump();
  }

  /// The same catch-up rule, per resume: inside the grace it runs, beyond it
  /// the row says `missed` — unless its owner said to resume however late.
  Future<bool> _reconcileResumes(DateTime now) async {
    var changed = false;
    for (final resume in _resumes.inState(ScheduledResumeState.queued)) {
      if (_resumeBlocker(resume) != null) continue;
      await fireResume(resume);
      changed = true;
    }
    for (final resume in _resumes.inState(ScheduledResumeState.pending)) {
      if (resume.fireAt.isAfter(now)) continue;
      final decision = missedFireDecision(
        schedule: AutomationSchedule.once(resume.fireAt),
        since: resume.scheduledAt.isBefore(resume.fireAt)
            ? resume.scheduledAt
            : resume.fireAt.subtract(const Duration(seconds: 1)),
        now: now,
        grace: resume.latePolicy == ResumeLatePolicy.resume
            ? now.difference(resume.fireAt) + kMissedFireGrace
            : kMissedFireGrace,
      );
      changed = true;
      if (decision is MissedFires) {
        final missed = ref
            .read(scheduledResumeControllerProvider)
            .end(
              resume,
              ScheduledResumeState.missed,
              missedResumeReason(decision.lateBy),
            );
        ref
            .read(resumeAnnouncerProvider)
            .announce(
              missed,
              ref.read(sessionDaoProvider).getById(resume.sessionId),
            );
        continue;
      }
      final late = now.difference(resume.fireAt);
      await fireResume(
        resume,
        note: late > kMissedFireGrace
            ? 'Karmashala was not running at the time, and you chose to '
                  'resume however late.'
            : '',
      );
    }
    return changed;
  }

  /// Fires [resume], or leaves it `queued` with the reason when its checkout
  /// already has an unattended owner.
  Future<void> fireResume(ScheduledResume resume, {String note = ''}) async {
    final blocker = _resumeBlocker(resume);
    if (blocker != null) {
      if (resume.state != ScheduledResumeState.queued ||
          resume.reason != blocker) {
        _resumes.update(
          resume.copyWith(state: ScheduledResumeState.queued, reason: blocker),
        );
        ref.read(automationsRevisionProvider.notifier).bump();
        ref.publishSessionChange(SessionChange.reconfigured(resume.sessionId));
      }
      return;
    }
    await ref.read(scheduledResumeFiringProvider).fire(resume, note: note);
  }

  /// Why [resume] has to wait for its checkout, or null. A session in its own
  /// worktree shares the checkout with nobody.
  String? _resumeBlocker(ScheduledResume resume) {
    final session = ref.read(sessionDaoProvider).getById(resume.sessionId);
    if (session == null || session.worktree != null) return null;
    final run = _liveInCheckout(session.repositoryId);
    if (run != null) return queuedReason(run);
    for (final other in _resumes.inState(ScheduledResumeState.firing)) {
      if (other.id == resume.id) continue;
      final theirs = ref.read(sessionDaoProvider).getById(other.sessionId);
      if (theirs == null || theirs.worktree != null) continue;
      if (theirs.repositoryId != session.repositoryId) continue;
      return 'This checkout is busy: "${theirs.title}" is being resumed there. '
          'One unattended run owns a checkout at a time, so this one is '
          'waiting rather than racing it.';
    }
    return null;
  }

  DateTime _floorFor(Automation automation) {
    final observed = _dao.lastObservedOccurrence(automation.id);
    if (observed == null) return automation.armedAt;
    return observed.isAfter(automation.armedAt) ? observed : automation.armedAt;
  }

  void _recordMissed(Automation automation, MissedFires missed, DateTime now) {
    _dao.insertRun(
      AutomationRun(
        id: _newId(),
        automationId: automation.id,
        scheduledFor: missed.scheduledFor,
        firedAt: now,
        state: AutomationRunState.missed,
        reason: missedFireReason(missed),
      ),
    );
    // A missed one-shot is over; it keeps its row rather than staying armed.
    if (automation.schedule.isOnce) {
      _dao.setEnabled(automation.id, enabled: false);
    }
  }

  /// Fires, or records a `queued` row when the checkout already has an owner:
  /// one unattended owner per checkout, and a run already waiting is not jumped.
  Future<void> _fireOrQueue(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
  }) async {
    final busy = _liveInCheckout(automation.repositoryId);
    if (busy != null) {
      _dao.insertRun(
        AutomationRun(
          id: _newId(),
          automationId: automation.id,
          scheduledFor: scheduledFor,
          firedAt: _now,
          state: AutomationRunState.queued,
          reason: queuedReason(busy),
        ),
      );
      return;
    }
    await ref
        .read(automationFiringProvider)
        .fire(automation, scheduledFor, note: note);
    // A one-shot has had its shot. Disabled, not deleted: the row is the record.
    if (automation.schedule.isOnce) {
      _dao.setEnabled(automation.id, enabled: false);
    }
  }

  /// What a queued row says, in the words the page shows.
  String queuedReason(AutomationRun owner) {
    final name = _dao.getById(owner.automationId)?.name ?? 'another automation';
    final what = owner.state == AutomationRunState.running
        ? '"$name" is running there'
        : '"$name" is already waiting for it';
    return 'This checkout is busy: $what. One unattended run owns a checkout '
        'at a time, so this one is waiting rather than racing it.';
  }

  /// The run that holds or is waiting on [repositoryId], or null when it is
  /// free. Oldest first, so the answer is the head of the queue.
  AutomationRun? _liveInCheckout(String repositoryId) {
    for (final run in _dao.liveRuns()) {
      final automation = _dao.getById(run.automationId);
      if (automation?.repositoryId == repositoryId) return run;
    }
    return null;
  }

  /// Starts the oldest waiting run for [repositoryId] when the checkout is
  /// free. Called when a run settles; this is what makes the queue a queue.
  Future<void> drain(String repositoryId) async {
    AutomationRun? waiting;
    for (final run in _dao.liveRuns()) {
      final automation = _dao.getById(run.automationId);
      if (automation == null || automation.repositoryId != repositoryId) {
        continue;
      }
      // Something is still running there. Nothing to drain into.
      if (run.state == AutomationRunState.running) return;
      waiting ??= run;
    }
    if (waiting == null) {
      await _drainResumes(repositoryId);
      return;
    }
    final automation = _dao.getById(waiting.automationId)!;
    // The waiting row *becomes* the run rather than a second row beside it.
    await ref
        .read(automationFiringProvider)
        .fire(
          automation,
          waiting.scheduledFor,
          note:
              'Queued behind another run in this checkout, then started when '
              'it came free.',
          queued: waiting,
        );
    ref.read(automationsRevisionProvider.notifier).bump();
  }

  /// Starts the oldest resume waiting on [repositoryId], now it is free.
  Future<void> _drainResumes(String repositoryId) async {
    for (final resume in _resumes.inState(ScheduledResumeState.queued)) {
      final session = ref.read(sessionDaoProvider).getById(resume.sessionId);
      if (session?.repositoryId != repositoryId) continue;
      if (_resumeBlocker(resume) != null) return;
      await fireResume(
        resume,
        note: 'Waited for the checkout to come free first.',
      );
      return;
    }
  }
}

/// The reason a `missed` resume carries. Never empty.
String missedResumeReason(Duration lateBy) {
  final minutes = lateBy.inMinutes;
  final late = minutes < 60
      ? '$minutes minute${minutes == 1 ? '' : 's'}'
      : '${lateBy.inHours} hour${lateBy.inHours == 1 ? '' : 's'}';
  return 'Karmashala was not running when this was due, $late ago. Only a '
      'resume within ${kMissedFireGrace.inMinutes} minutes is caught up '
      'unasked — resume it now if you still want it.';
}

final automationSchedulerProvider = NotifierProvider<AutomationScheduler, int>(
  AutomationScheduler.new,
);
