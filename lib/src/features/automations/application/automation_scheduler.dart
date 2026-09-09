import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../data/automation_dao.dart';
import '../domain/automation.dart';
import '../domain/automation_run.dart';
import '../domain/cron_schedule.dart';
import '../domain/missed_fires.dart';
import 'automation_providers.dart';
import 'automation_runner.dart';
import 'automation_timer.dart';

/// What happens when an occurrence comes due.
///
/// The scheduler decides *when*; this decides *what* — the gate again, a
/// checkpoint of the base, and a session. Its implementation is
/// `automation_runner.dart`; it is a seam so the scheduler's own rules can be
/// tested against a recorder rather than against a real agent.
///
/// **Its contract is that it always records a run for the occurrence**,
/// whatever happens — a gate refusal at fire time is a `failed` row, not a
/// silent return. The scheduler's floor is the newest occurrence it has a row
/// for, so a fire that recorded nothing would be found due again on the next
/// tick, forever.
abstract interface class AutomationFiring {
  /// Starts [automation] for the occurrence due at [scheduledFor].
  ///
  /// [note] explains an out-of-band fire — today, that it is catching up on a
  /// schedule the app was not running for. It rides along on whatever the run
  /// settles as, so the record says why it happened off schedule.
  ///
  /// [queued] is the waiting row this fire *is*, when the checkout came free
  /// and the queue drained. It is updated rather than replaced: the row
  /// already carries the occurrence it is about, so inserting a second would
  /// report one fire twice.
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

/// Longest a single timer is armed for, after which it re-arms.
///
/// Not a poll: the re-arm computes the next occurrence again from the same
/// data, and a workspace with nothing scheduled arms nothing at all. It exists
/// so a schedule six months out is not one `Timer` holding a six-month
/// duration across a suspend.
const Duration kMaxTimerDelay = Duration(hours: 24);

/// One armed timer for the next occurrence across every automation.
///
/// **Nothing sweeps and nothing polls (§19).** The timer is armed for the
/// single soonest occurrence, and re-armed after each fire and on any change —
/// a save, a pause, a delete, a run settling. A sweep would be the thing this
/// is not: a wake-up on a fixed cadence asking "is anything due yet".
///
/// **One code path for a punctual fire and a late one.** A fire that is on
/// time is a catch-up that is nought minutes late, so the timer runs exactly
/// the rules the boot sweep does. That is what stops a laptop that slept
/// through 03:00 from firing at 09:00 as though it were punctual — it lands in
/// the miss rules and is recorded as a miss, with its reason.
///
/// **It has to be watched, not read.** Riverpod 3 pauses a provider's own
/// subscriptions while nothing listens to it, so a scheduler nobody watches
/// would arm nothing — silently. `AppShell` watches it, beside
/// `worktreeSetupExitObserverProvider`, which documents the same hazard.
class AutomationScheduler extends Notifier<int> {
  /// Whether the one boot sweep this process gets has run. Kept on the
  /// notifier rather than in [state] because [build] re-runs on every change
  /// and has to carry it across.
  bool _reconciled = false;

  @override
  int build() {
    final revision = ref.watch(automationsRevisionProvider);
    final timer = ref.watch(automationTimerProvider);
    ref.onDispose(timer.cancel);

    arm();

    // Arming only ever covers fires from now on. Anything due while the
    // process was down is accounted for separately, and never at the cost of
    // arming — deferred so every automation is armed before any of them starts
    // competing for a checkout.
    if (!_reconciled) {
      _reconciled = true;
      unawaited(Future<void>.microtask(reconcile));
    }
    return revision;
  }

  AutomationDao get _dao => ref.read(automationDaoProvider);
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
    // Re-armed here as well as by the rebuild a write triggers, because a tick
    // that found nothing to do writes nothing — and a timer that fired and did
    // not re-arm is a scheduler that has quietly stopped.
    arm();
  }

  /// Account for every occurrence due since each automation was last watched.
  ///
  /// Run at start-up and after every timer fire. The floor is the newest
  /// occurrence this install already recorded something about, never earlier
  /// than the moment a person armed it — without that floor, arming a
  /// brand-new automation would "discover" every occurrence since the epoch.
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
          // Everything older than the one being run is a miss with a reason —
          // "at most one catch-up run, for the newest missed occurrence only".
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
    if (changed) ref.read(automationsRevisionProvider.notifier).bump();
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
    // A one-shot that was missed is over. It keeps its row and its reason; it
    // does not sit armed for a moment that has passed.
    if (automation.schedule.isOnce) {
      _dao.setEnabled(automation.id, enabled: false);
    }
  }

  /// Fires, or records a `queued` row when the checkout already has an owner.
  ///
  /// **One unattended owner per checkout.** A fire arriving while anything is
  /// live in the same checkout is enqueued, not started — two agents editing
  /// one working tree is the race this refuses to have, and a run already
  /// waiting there is not jumped either.
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
    // A one-shot has now had its one shot. Disabled rather than deleted: the
    // row and its runs are what the user goes back to.
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

  /// Starts the oldest waiting run for [repositoryId], if the checkout is free.
  ///
  /// Called when a run settles. This is what makes the queue a queue rather
  /// than a list of runs that never happened.
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
    if (waiting == null) return;
    final automation = _dao.getById(waiting.automationId)!;
    // The waiting row *becomes* the run rather than a second row beside it.
    await ref
        .read(automationFiringProvider)
        .fire(
          automation,
          waiting.scheduledFor,
          note: 'Queued behind another run in this checkout, then started when '
              'it came free.',
          queued: waiting,
        );
    ref.read(automationsRevisionProvider.notifier).bump();
  }
}

final automationSchedulerProvider = NotifierProvider<AutomationScheduler, int>(
  AutomationScheduler.new,
);
