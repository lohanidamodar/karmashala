import 'dart:async';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/scheduler.dart' as scheduling;
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../git/application/worktree_cleanup_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'automation_providers.dart';
import 'automation_runner.dart';
import 'automation_timer.dart';
import 'host_automations.dart';
import 'scheduled_resume_providers.dart';
import 'scheduled_resume_runner.dart';

export 'package:karmashala_automations/scheduler.dart'
    show AutomationFiring, kMaxTimerDelay, missedResumeReason;

/// The real one is the app's `AutomationRunner`; tests override it.
final automationFiringProvider = Provider<scheduling.AutomationFiring>(
  (ref) => ref.watch(automationRunnerProvider),
);

/// The one timer for automations, resumes and worktree cleanup, in this app.
/// Where a session host runs automations it fires them and this keeps only
/// worktree cleanup; edits and event runs are handed to the host. Must be
/// watched, or Riverpod 3 pauses it and it arms nothing.
class AutomationScheduler extends Notifier<int> {
  scheduling.AutomationScheduler? _scheduler;
  DateTime? _availableSince;

  @override
  int build() {
    final atHost = ref.watch(automationsAtHostProvider);
    final timer = ref.watch(automationTimerProvider);
    ref.onDispose(timer.cancel);

    // Built once per mode: its ports read through this build's `ref`.
    final scheduler = _scheduler = _build(timer, atHost: atHost);
    _availableSince ??= scheduler.availableSince;
    _atHost = atHost;
    ref.onDispose(scheduler.stop);

    // Every write re-arms at once, in the writer's own turn: a rebuild would
    // arm a turn later, after a timer already asked to fire.
    ref.listen(automationsRevisionProvider, (_, _) => scheduler.arm());
    // Worktree cleanup rides this timer rather than keeping one of its own.
    ref.listen(worktreeCleanupRevisionProvider, (_, _) => scheduler.arm());
    scheduler.arm();

    // What was due while this process was down, once, after everything is
    // armed.
    unawaited(
      Future<void>.microtask(() async {
        if (!scheduler.stopped) await scheduler.reconcile();
      }),
    );
    return 0;
  }

  var _atHost = false;

  scheduling.AutomationScheduler _build(
    scheduling.AutomationTimer timer, {
    required bool atHost,
  }) => scheduling.AutomationScheduler(
    automations: ref.read(automationDaoProvider),
    resumes: ref.read(scheduledResumeDaoProvider),
    sessionOf: (id) => ref.read(sessionsDataProvider).getById(id),
    firing: _LateFiring(() => ref.read(automationFiringProvider)),
    resumeFiring: _LateResumeFiring(
      () => ref.read(scheduledResumeFiringProvider),
    ),
    timer: timer,
    now: () => ref.read(clockProvider).nowUtc(),
    newId: () => ref.read(idGeneratorProvider).newId(),
    chores: [_WorktreeCleanupChore(ref)],
    firesAutomations: !atHost,
    availableSince: _availableSince,
    onChanged: () => ref.read(automationsRevisionProvider.notifier).bump(),
    onResumeChanged: (sessionId) =>
        ref.publishSessionChange(SessionChange.reconfigured(sessionId)),
    onResumeEnded: (ended) => ref
        .read(resumeAnnouncerProvider)
        .announce(ended, ref.read(sessionsDataProvider).getById(ended.sessionId)),
  );

  scheduling.AutomationScheduler get _core => _scheduler!;

  DateTime? nextOccurrence(DateTime after) => _core.nextOccurrence(after);

  void arm() => _core.arm();

  /// Accounts for what is due. At a host, asks the host to.
  Future<void> reconcile() async {
    if (_atHost) ref.read(hostAutomationsLinkProvider).notifyChanged();
    await _core.reconcile();
  }

  Future<void> fireResume(ScheduledResume resume, {String note = ''}) =>
      _core.fireResume(resume, note: note);

  /// Lets the next waiting run in [repositoryId] start. At a host, the host
  /// drains its own queue once told something changed.
  Future<void> drain(String repositoryId) async {
    if (_atHost) {
      ref.read(hostAutomationsLinkProvider).notifyChanged();
      return;
    }
    await _core.drain(repositoryId);
  }

  /// Starts an event rule's run under a scheduled fire's rules. At a host the
  /// run is queued in the store and the host starts it.
  Future<void> startEventRun(Automation automation, AutomationRun run) async {
    if (_atHost) {
      _core.queueEventRun(automation, run);
      ref.read(hostAutomationsLinkProvider).notifyChanged();
      return;
    }
    await _core.startEventRun(automation, run);
  }

  String queuedReason(AutomationRun owner) => _core.queuedReason(owner);
}

final automationSchedulerProvider = NotifierProvider<AutomationScheduler, int>(
  AutomationScheduler.new,
);

/// Read at fire time, so a test's override is the one that fires.
class _LateFiring implements scheduling.AutomationFiring {
  _LateFiring(this._firing);
  final scheduling.AutomationFiring Function() _firing;

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) => _firing().fire(automation, scheduledFor, note: note, queued: queued);
}

class _LateResumeFiring implements scheduling.ScheduledResumeFiring {
  _LateResumeFiring(this._firing);
  final scheduling.ScheduledResumeFiring Function() _firing;

  @override
  Future<void> fire(ScheduledResume resume, {String note = ''}) =>
      _firing().fire(resume, note: note);
}

class _WorktreeCleanupChore implements scheduling.SchedulerChore {
  _WorktreeCleanupChore(this._ref);
  final Ref _ref;

  @override
  DateTime? nextDue({required DateTime availableSince}) => _ref
      .read(worktreeCleanupControllerProvider)
      .nextDue(availableSince: availableSince);

  @override
  void startIfDue(DateTime now, {required DateTime availableSince}) => _ref
      .read(worktreeCleanupControllerProvider)
      .startIfDue(now, availableSince: availableSince);
}
