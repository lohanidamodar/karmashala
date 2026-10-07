import 'dart:async';

import 'package:karmashala_session/session.dart';

import '../domain/automation.dart';
import '../domain/automation_admission.dart';
import '../domain/automation_run.dart';
import '../domain/cron_schedule.dart';
import '../domain/missed_fires.dart';
import '../domain/scheduled_resume.dart';
import 'automation_firing.dart';
import 'automation_records.dart';
import 'automation_timer.dart';

/// Longest a single timer is armed for, after which it re-arms: a schedule six
/// months out is not one `Timer` across a suspend.
const Duration kMaxTimerDelay = Duration(hours: 24);

/// One armed timer for the next occurrence across every automation and every
/// scheduled resume; nothing polls. Runs in the server.
class AutomationScheduler {
  AutomationScheduler({
    required AutomationRecords automations,
    required this._resumes,
    required this._sessionOf,
    required this._firing,
    required this._resumeFiring,
    required this._timer,
    required DateTime Function() now,
    required this._newId,
    void Function()? onChanged,
    void Function(String sessionId)? onResumeChanged,
    void Function(ScheduledResume ended)? onResumeEnded,
    DateTime? availableSince,
  }) : _dao = automations,
       _now = now,
       _onChanged = onChanged ?? _nothing,
       _onResumeChanged = onResumeChanged ?? _nothingFor,
       _onResumeEnded = onResumeEnded ?? _nothingEnded,
       availableSince = availableSince ?? now();

  final AutomationRecords _dao;
  final ResumeRecords _resumes;
  final Session? Function(String sessionId) _sessionOf;
  final AutomationFiring _firing;
  final ScheduledResumeFiring _resumeFiring;
  final AutomationTimer _timer;
  final DateTime Function() _now;
  final String Function() _newId;
  final void Function() _onChanged;
  final void Function(String sessionId) _onResumeChanged;
  final void Function(ScheduledResume ended) _onResumeEnded;

  static void _nothing() {}
  static void _nothingFor(String _) {}
  static void _nothingEnded(ScheduledResume _) {}

  /// When this process started watching (a rebuilt scheduler is handed the
  /// first one's). Only an occurrence due before it was missed to downtime;
  /// one due after it and seen late is latency.
  final DateTime availableSince;

  bool get stopped => _stopped;

  var _stopped = false;

  /// Arms the timer and accounts for what was due while nobody was watching.
  Future<void> start() async {
    arm();
    await reconcile();
    arm();
  }

  /// Disarms; nothing fires after this.
  void stop() {
    _stopped = true;
    _timer.cancel();
  }

  /// The enabled automations the clock fires; an event rule has no schedule.
  Iterable<Automation> get _scheduled =>
      _dao.enabled().where((automation) => automation.isScheduled);

  /// The soonest moment anything is due, or null when nothing ever is.
  DateTime? nextOccurrence(DateTime after) {
    DateTime? soonest;
    void consider(DateTime? next) {
      if (next == null) return;
      final at = next.isAfter(after) ? next : after;
      if (soonest == null || at.isBefore(soonest!)) soonest = at;
    }

    for (final automation in _scheduled) {
      final next = _nextFor(automation, after);
      if (next != null && (soonest == null || next.isBefore(soonest!))) {
        soonest = next;
      }
    }
    for (final resume in _resumes.inState(ScheduledResumeState.pending)) {
      consider(resume.fireAt);
    }
    // A run with a ceiling has a moment of its own, which a held checkout
    // would otherwise never reach.
    for (final run in _dao.liveRuns()) {
      if (run.state != AutomationRunState.running) continue;
      final ceiling = _dao.getById(run.automationId)?.maxRuntime;
      if (ceiling != null) consider(run.firedAt.add(ceiling));
    }
    return soonest;
  }

  DateTime? _nextFor(Automation automation, DateTime after) {
    final schedule = automation.schedule;
    if (schedule.isOnce) {
      final at = schedule.firesAt!;
      return at.isAfter(after) ? at : null;
    }
    if (schedule.isInterval) {
      // From the finish, never from the clock: a run still going has no next
      // occurrence yet.
      if (_dao.liveRunOf(automation.id) != null) return null;
      final due = _intervalFloor(automation).add(schedule.gap!);
      return due.isAfter(after) ? due : after;
    }
    return CronSchedule.parse(schedule.cron!)?.nextAfter(after);
  }

  DateTime _intervalFloor(Automation automation) {
    final finished = _dao.lastFinishedAt(automation.id);
    if (finished == null) return automation.armedAt;
    return finished.isAfter(automation.armedAt) ? finished : automation.armedAt;
  }

  /// Arms the one timer for the next occurrence, replacing whatever was armed.
  void arm() {
    if (_stopped) return;
    final now = _now();
    final next = nextOccurrence(now);
    if (next == null) {
      _timer.cancel();
      return;
    }
    final delay = next.difference(now);
    _timer.arm(delay > kMaxTimerDelay ? kMaxTimerDelay : delay, () {
      unawaited(_onTimer());
    });
  }

  Future<void> _onTimer() async {
    if (_stopped) return;
    await reconcile();
    // A tick that found nothing writes nothing, so nothing else re-arms it.
    arm();
  }

  /// Accounts for every occurrence due since each automation was last
  /// watched, fires what is due, and drains every free checkout's queue.
  Future<void> reconcile() async {
    if (_stopped) return;
    final now = _now();
    var changed = _reapOverrunning(now);
    for (final automation in _scheduled) {
      final decision = missedFireDecision(
        schedule: automation.schedule,
        since: _floorFor(automation),
        now: now,
        grace: _graceFor(automation, now),
        availableSince: automation.latePolicy == AutomationLatePolicy.skip
            ? availableSince
            : null,
      );
      // One run of an automation at a time; the occurrence is recorded, never
      // silently dropped.
      final live = _dao.liveRunOf(automation.id);
      if (live != null) {
        if (automation.schedule.isInterval) continue;
        final due = switch (decision) {
          MissedFires(:final scheduledFor) => scheduledFor,
          CatchUpMissedFire(:final scheduledFor) => scheduledFor,
          NoMissedFires() => null,
        };
        if (due != null) {
          _recordSkipped(automation, due, now, _alreadyRunningReason(live));
          changed = true;
        }
        continue;
      }
      switch (decision) {
        case NoMissedFires():
          continue;
        case MissedFires():
          _recordMissed(automation, decision, now);
          changed = true;
        case CatchUpMissedFire():
          final older = decision.older;
          if (older != null) _recordMissed(automation, older, now);
          await _fireOrQueue(
            automation,
            decision.scheduledFor,
            note: decision.missedCount > 1 ? caughtUpReason(decision) : '',
          );
          changed = true;
          // Stopped mid-sweep (a shutdown): nothing more is started.
          if (_stopped) return;
      }
    }
    // Only awaited when there is something to start: a reconcile with nothing
    // queued takes no extra turn.
    for (final repositoryId in _freeQueuedCheckouts()) {
      await drain(repositoryId);
      changed = true;
      if (_stopped) return;
    }
    if (await _reconcileResumes(now)) changed = true;
    if (_stopped) return;
    if (changed) _onChanged();
  }

  /// Fails a run that has held its checkout past its ceiling and frees the
  /// queue behind it. **The agent's own process is left running.**
  bool _reapOverrunning(DateTime now) {
    var changed = false;
    for (final run in _dao.liveRuns()) {
      if (run.state != AutomationRunState.running) continue;
      final automation = _dao.getById(run.automationId);
      final ceiling = automation?.maxRuntime;
      if (automation == null || ceiling == null) continue;
      final ranFor = now.difference(run.firedAt);
      if (ranFor <= ceiling) continue;
      _dao.updateRun(
        run.copyWith(
          state: AutomationRunState.failed,
          finishedAt: now,
          reason:
              'Gave up waiting after ${describeGap(ranFor)}, past the '
              '${describeGap(ceiling)} this automation allows. The checkout is '
              'free again for whatever is waiting. **The agent itself was not '
              'stopped** — it may still be working, and ending it mid-edit '
              'would be worse than a late run; end its session yourself if it '
              'is stuck.',
        ),
      );
      _dao.recordOutcome(run.automationId, failed: true);
      changed = true;
      unawaited(drain(automation.repositoryId));
    }
    return changed;
  }

  /// The checkouts with a run waiting and none running — what makes a run
  /// another process queued (an event rule the app heard) start.
  Set<String> _freeQueuedCheckouts() {
    final busy = <String>{};
    final waiting = <String>{};
    for (final run in _dao.liveRuns()) {
      final repositoryId = _dao.getById(run.automationId)?.repositoryId;
      if (repositoryId == null) continue;
      if (run.state == AutomationRunState.running) busy.add(repositoryId);
      if (run.state == AutomationRunState.queued) waiting.add(repositoryId);
    }
    return waiting.difference(busy);
  }

  /// The same catch-up rule, per resume: inside the grace it runs, beyond it
  /// the row says `missed` — unless its owner said to resume however late.
  Future<bool> _reconcileResumes(DateTime now) async {
    var changed = false;
    for (final resume in _resumes.inState(ScheduledResumeState.queued)) {
      if (resumeBlocker(resume) != null) continue;
      await fireResume(resume);
      changed = true;
      if (_stopped) return changed;
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
        endResume(
          resume,
          ScheduledResumeState.missed,
          missedResumeReason(decision.lateBy),
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
      if (_stopped) return changed;
    }
    return changed;
  }

  /// Writes how [resume] ended and tells whoever announces it.
  ScheduledResume endResume(
    ScheduledResume resume,
    ScheduledResumeState state,
    String reason,
  ) {
    final ended = resume.copyWith(
      state: state,
      reason: reason,
      finishedAt: _now(),
    );
    _resumes.update(ended);
    _onResumeChanged(ended.sessionId);
    _onResumeEnded(ended);
    return ended;
  }

  /// Fires [resume], or leaves it `queued` with the reason when its checkout
  /// already has an unattended owner.
  Future<void> fireResume(ScheduledResume resume, {String note = ''}) async {
    final blocker = resumeBlocker(resume);
    if (blocker != null) {
      if (resume.state != ScheduledResumeState.queued ||
          resume.reason != blocker) {
        _resumes.update(
          resume.copyWith(state: ScheduledResumeState.queued, reason: blocker),
        );
        _onChanged();
        _onResumeChanged(resume.sessionId);
      }
      return;
    }
    await _resumeFiring.fire(resume, note: note);
  }

  /// Why [resume] has to wait for its checkout, or null. A session in its own
  /// worktree shares the checkout with nobody.
  String? resumeBlocker(ScheduledResume resume) {
    final session = _sessionOf(resume.sessionId);
    if (session == null || session.worktree != null) return null;
    final run = _liveInCheckout(session.repositoryId);
    if (run != null) return queuedReason(run);
    for (final other in _resumes.inState(ScheduledResumeState.firing)) {
      if (other.id == resume.id) continue;
      final theirs = _sessionOf(other.sessionId);
      if (theirs == null || theirs.worktree != null) continue;
      if (theirs.repositoryId != session.repositoryId) continue;
      return 'This checkout is busy: "${theirs.title}" is being resumed there. '
          'One unattended run owns a checkout at a time, so this one is '
          'waiting rather than racing it.';
    }
    return null;
  }

  DateTime _floorFor(Automation automation) {
    // An interval counts from its last finish, floored at the newest
    // occurrence anything recorded, so a filed miss is not filed again.
    if (automation.schedule.isInterval) {
      final finish = _intervalFloor(automation);
      final touched = _dao.lastTouchedAt(automation.id);
      if (touched == null || finish.isAfter(touched)) return finish;
      return touched;
    }
    final observed = _dao.lastObservedOccurrence(automation.id);
    if (observed == null) return automation.armedAt;
    return observed.isAfter(automation.armedAt) ? observed : automation.armedAt;
  }

  Duration _graceFor(Automation automation, DateTime now) =>
      switch (automation.latePolicy) {
        AutomationLatePolicy.run =>
          now.difference(automation.armedAt).abs() + kMissedFireGrace,
        AutomationLatePolicy.ask => kMissedFireGrace,
        AutomationLatePolicy.skip => kSchedulerLatencyTolerance,
      };

  void _recordSkipped(
    Automation automation,
    DateTime scheduledFor,
    DateTime now,
    String reason,
  ) => _dao.insertRun(
    AutomationRun(
      id: _newId(),
      automationId: automation.id,
      scheduledFor: scheduledFor,
      firedAt: now,
      state: AutomationRunState.missed,
      reason: reason,
    ),
  );

  String _alreadyRunningReason(AutomationRun live) =>
      alreadyRunningReason(live);

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

  /// Fires, or records a `queued` row when the checkout already has an owner.
  Future<void> _fireOrQueue(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
  }) async {
    final now = _now();
    final overHour = hourlyRefusal(
      automation,
      recent: _dao.runsFor(automation.id, limit: recentRunsToRead(automation)),
      now: now,
    );
    if (overHour != null) {
      _recordSkipped(automation, scheduledFor, now, overHour);
      return;
    }
    final busy = _liveInCheckout(automation.repositoryId);
    if (busy != null) {
      _dao.insertRun(
        AutomationRun(
          id: _newId(),
          automationId: automation.id,
          scheduledFor: scheduledFor,
          firedAt: _now(),
          state: AutomationRunState.queued,
          reason: queuedReason(busy),
        ),
      );
      return;
    }
    await _firing.fire(automation, scheduledFor, note: note);
    // A one-shot has had its shot. Disabled, not deleted: the row is the record.
    if (automation.schedule.isOnce) {
      _dao.setEnabled(automation.id, enabled: false);
    }
  }

  /// Writes an event rule's [run] as `queued` (or `missed` when the rule is
  /// already running one) without firing it; a scheduler that drains the
  /// checkout starts it. Returns the row written.
  AutomationRun queueEventRun(Automation automation, AutomationRun run) {
    final written = queueEventRunIn(_dao, automation, run);
    _onChanged();
    return written;
  }

  /// What a queued row says, in the words the page shows.
  String queuedReason(AutomationRun owner) => queuedReasonIn(_dao, owner);

  AutomationRun? _liveInCheckout(String repositoryId) =>
      liveInCheckout(_dao, repositoryId);

  /// Starts the oldest waiting run for [repositoryId] when the checkout is
  /// free. Called when a run settles; this is what makes the queue a queue.
  Future<void> drain(String repositoryId) async {
    if (_stopped) return;
    final here = [
      for (final run in _dao.liveRuns())
        if (_dao.getById(run.automationId)?.repositoryId == repositoryId) run,
    ];
    final running = here.where((r) => r.state == AutomationRunState.running);
    AutomationRun? waiting;
    var checkoutQueueWaits = false;
    for (final run in here) {
      if (run.state != AutomationRunState.queued) continue;
      final lane = runLane(run);
      // A pull request's run has a worktree of its own: it waits only for
      // its automation's run on the same branch, never for the checkout.
      final blocked = lane.isEmpty
          ? checkoutQueueWaits || running.any((r) => runLane(r).isEmpty)
          : running.any(
              (r) => r.automationId == run.automationId && runLane(r) == lane,
            );
      if (!blocked) {
        waiting = run;
        break;
      }
      if (lane.isEmpty) checkoutQueueWaits = true;
    }
    if (waiting == null && running.isNotEmpty) return;
    if (waiting == null) {
      await _drainResumes(repositoryId);
      return;
    }
    final automation = _dao.getById(waiting.automationId)!;
    // An event run queued by another process keeps its "because" line unless
    // it really waited behind somebody.
    final waitedBehind = waiting.reason.startsWith('This checkout is busy');
    // The waiting row *becomes* the run rather than a second row beside it.
    await _firing.fire(
      automation,
      waiting.scheduledFor,
      note:
          (waiting.eventSessionId != null || waiting.startedBy != null) &&
              !waitedBehind
          ? waiting.reason
          : 'Queued behind another run in this checkout, then started when '
                'it came free.',
      queued: waiting,
    );
    if (_stopped) return;
    _onChanged();
    arm();
  }

  Future<void> _drainResumes(String repositoryId) async {
    for (final resume in _resumes.inState(ScheduledResumeState.queued)) {
      final session = _sessionOf(resume.sessionId);
      if (session?.repositoryId != repositoryId) continue;
      if (resumeBlocker(resume) != null) return;
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

/// Writes an event rule's [run] into [records]: `queued` behind whatever holds
/// its checkout, or `missed` when the rule already has a run live. Returns the
/// row written; whichever scheduler drains the checkout starts it.
AutomationRun queueEventRunIn(
  AutomationRecords records,
  Automation automation,
  AutomationRun run,
) {
  final admission = admitRun(
    automation,
    lane: runLane(run),
    recent: records.runsFor(automation.id, limit: recentRunsToRead(automation)),
    now: run.firedAt,
    byPerson: run.startedBy == AutomationRunCause.runNow,
  );
  switch (admission) {
    case AdmitRefuse(:final reason):
      final missed = run.copyWith(
        state: AutomationRunState.missed,
        reason: reason,
      );
      records.insertRun(missed);
      return missed;
    case AdmitQueue(:final reason):
      final queued = run.copyWith(
        state: AutomationRunState.queued,
        reason: reason,
      );
      records.insertRun(queued);
      return queued;
    case AdmitStart():
      break;
  }
  final busy = liveInCheckout(records, automation.repositoryId);
  final queued = run.copyWith(
    state: AutomationRunState.queued,
    reason: busy == null ? run.reason : queuedReasonIn(records, busy),
  );
  records.insertRun(queued);
  return queued;
}

/// The run that holds or is waiting on [repositoryId], oldest first.
AutomationRun? liveInCheckout(AutomationRecords records, String repositoryId) {
  for (final run in records.liveRuns()) {
    if (records.getById(run.automationId)?.repositoryId == repositoryId) {
      return run;
    }
  }
  return null;
}

/// What a row queued behind [owner] says, in the words the page shows.
String queuedReasonIn(AutomationRecords records, AutomationRun owner) {
  final name =
      records.getById(owner.automationId)?.name ?? 'another automation';
  final what = owner.state == AutomationRunState.running
      ? '"$name" is running there'
      : '"$name" is already waiting for it';
  return 'This checkout is busy: $what. One unattended run owns a checkout '
      'at a time, so this one is waiting rather than racing it.';
}

/// Why an occurrence was not started beside [live], the rule's own run.
String alreadyRunningReason(AutomationRun live) =>
    live.state == AutomationRunState.running
    ? 'This automation was still running the occurrence due '
          '${live.scheduledFor.toLocal()}, so this one was not started. One '
          'run of an automation at a time — the same prompt twice over is '
          'not the schedule doing its job.'
    : 'This automation already had the occurrence due '
          '${live.scheduledFor.toLocal()} waiting for its checkout, so this '
          'one was not queued behind it as well.';
