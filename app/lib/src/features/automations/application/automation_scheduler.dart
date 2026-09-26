import 'dart:async';

import 'package:karmashala_automations/scheduler.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../git/application/worktree_cleanup_providers.dart';
import 'automation_timer.dart';

/// This app's one timer, for what only it does on a clock: worktree cleanup.
/// Automations and resumes are the server's to fire. Must be watched, or
/// Riverpod 3 pauses it and it arms nothing.
class AutomationScheduler extends Notifier<int> {
  DateTime? _availableSince;
  var _stopped = false;

  @override
  int build() {
    final timer = _timer = ref.watch(automationTimerProvider);
    _stopped = false;
    ref.onDispose(() {
      _stopped = true;
      timer.cancel();
    });
    _availableSince ??= _now();
    ref.listen(worktreeCleanupRevisionProvider, (_, _) => arm());
    arm();
    return 0;
  }

  late AutomationTimer _timer;

  DateTime _now() => ref.read(clockProvider).nowUtc();

  WorktreeCleanupController get _cleanup =>
      ref.read(worktreeCleanupControllerProvider);

  /// Arms the timer for the cleanup's next moment, or disarms it.
  void arm() {
    if (_stopped) return;
    final due = _cleanup.nextDue(availableSince: _availableSince!);
    if (due == null) {
      _timer.cancel();
      return;
    }
    final delay = due.difference(_now());
    _timer.arm(delay > kMaxTimerDelay ? kMaxTimerDelay : delay, () {
      unawaited(reconcile());
      arm();
    });
  }

  /// Starts the cleanup when it is due.
  Future<void> reconcile() async {
    if (_stopped) return;
    _cleanup.startIfDue(_now(), availableSince: _availableSince!);
  }
}

final automationSchedulerProvider = NotifierProvider<AutomationScheduler, int>(
  AutomationScheduler.new,
);
