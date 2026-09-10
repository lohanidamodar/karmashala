import 'dart:async';

import 'package:riverpod/riverpod.dart';

/// The one armed timer the scheduler owns, behind a seam so a test can fire it
/// rather than wait for it — timing is a flake looking for a busy machine.
abstract interface class AutomationTimer {
  /// Replaces whatever was armed with one shot [delay] from now.
  void arm(Duration delay, void Function() onFire);

  /// Disarms. Safe when nothing is armed.
  void cancel();
}

/// The real one. Exactly one [Timer] is alive at a time.
class WallClockAutomationTimer implements AutomationTimer {
  Timer? _timer;

  @override
  void arm(Duration delay, void Function() onFire) {
    _timer?.cancel();
    _timer = Timer(delay.isNegative ? Duration.zero : delay, onFire);
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// A timer a test drives by hand. [armedFor] is what the scheduler asked for,
/// so "it armed for the next occurrence" is asserted without waiting.
class ManualAutomationTimer implements AutomationTimer {
  Duration? armedFor;
  void Function()? _onFire;

  /// How many times [arm] has been called. A re-arm after every fire and on
  /// every change is the difference between this and a sweep.
  int arms = 0;

  bool get isArmed => _onFire != null;

  @override
  void arm(Duration delay, void Function() onFire) {
    armedFor = delay;
    _onFire = onFire;
    arms++;
  }

  @override
  void cancel() {
    armedFor = null;
    _onFire = null;
  }

  /// Fires whatever is armed. Does nothing when nothing is.
  void fire() {
    final callback = _onFire;
    if (callback == null) return;
    _onFire = null;
    callback();
  }
}

final automationTimerProvider = Provider<AutomationTimer>((ref) {
  final timer = WallClockAutomationTimer();
  ref.onDispose(timer.cancel);
  return timer;
});
