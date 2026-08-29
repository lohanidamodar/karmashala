import 'dart:async';

/// How often live panes are re-snapshotted.
///
/// This is the trigger that actually matters: the app is a Windows desktop app
/// with close-to-tray, so a window close terminates the process without the
/// widget tree — and therefore the provider container — being disposed. 20 s
/// bounds the worst-case loss at 20 s of output.
const Duration kScrollbackAutosaveInterval = Duration(seconds: 20);

/// Schedules a repeating callback, returning a handle that [CancelSchedule] can
/// stop. Injected so tests drive the policy with no real clock.
typedef RepeatingSchedule =
    Object Function(Duration interval, void Function() callback);

typedef CancelSchedule = void Function(Object handle);

/// Runs [onTick] on an interval while started.
///
/// Thin on purpose: the interesting logic (which panes are dirty, what gets
/// written) belongs to the controller. This exists so that policy is testable
/// without waiting 20 real seconds.
class ScrollbackAutosave {
  ScrollbackAutosave({
    required this.onTick,
    this.interval = kScrollbackAutosaveInterval,
    RepeatingSchedule? schedule,
    CancelSchedule? cancel,
  }) : _schedule = schedule ?? _defaultSchedule,
       _cancel = cancel ?? _defaultCancel;

  final void Function() onTick;
  final Duration interval;
  final RepeatingSchedule _schedule;
  final CancelSchedule _cancel;

  Object? _handle;

  bool get isRunning => _handle != null;

  void start() {
    if (_handle != null) return;
    _handle = _schedule(interval, onTick);
  }

  void stop() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    _cancel(handle);
  }

  static Object _defaultSchedule(
    Duration interval,
    void Function() callback,
  ) => Timer.periodic(interval, (_) => callback());

  static void _defaultCancel(Object handle) => (handle as Timer).cancel();
}
