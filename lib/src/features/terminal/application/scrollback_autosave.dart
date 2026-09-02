import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How often live panes are re-snapshotted when everything is up to date.
///
/// This is the trigger that actually matters: the app is a Windows desktop app
/// with close-to-tray, so a window close terminates the process without the
/// widget tree — and therefore the provider container — being disposed. 20 s
/// bounds the worst-case loss at 20 s of output.
const Duration kScrollbackAutosaveInterval = Duration(seconds: 20);

/// How soon the next batch runs when the last tick left panes unsaved.
///
/// The app's scale target is 100 live terminals, and a
/// tick is deliberately capped at [kScrollbackAutosaveBudget] rather than
/// allowed to walk every dirty pane — so with a hundred busy panes one tick
/// cannot get through them all. Coming back in a second drains the backlog at a
/// bounded rate instead of doing it all at once: the UI isolate gives up ~8 ms
/// per second rather than freezing for 645 ms every 20.
const Duration kScrollbackAutosaveCatchUp = Duration(seconds: 1);

/// Most main-isolate time one autosave tick may spend.
///
/// Half a 60 Hz frame. The point is that the cost of a tick is **constant in
/// the number of panes**: whatever is not saved this time stays dirty and is
/// picked up by the catch-up tick.
const Duration kScrollbackAutosaveBudget = Duration(milliseconds: 8);

/// Schedules a one-shot callback, returning a handle that [CancelSchedule] can
/// stop. Injected so tests drive the policy with no real clock.
typedef DelayedSchedule =
    Object Function(Duration delay, void Function() callback);

typedef CancelSchedule = void Function(Object handle);

/// Runs [onTick] on an interval while started, coming back sooner when a tick
/// reports it left work behind.
///
/// Thin on purpose: the interesting logic (which panes are dirty, what gets
/// written) belongs to the controller. This exists so that policy is testable
/// without waiting 20 real seconds.
class ScrollbackAutosave {
  ScrollbackAutosave({
    required this.onTick,
    this.interval = kScrollbackAutosaveInterval,
    this.catchUpInterval = kScrollbackAutosaveCatchUp,
    DelayedSchedule? schedule,
    CancelSchedule? cancel,
  }) : _schedule = schedule ?? _defaultSchedule,
       _cancel = cancel ?? _defaultCancel;

  /// Runs one batch. Returns whether panes were left unsaved, which is what
  /// decides how long until the next one.
  final bool Function() onTick;

  /// The idle cadence — used when a tick saved everything it found.
  final Duration interval;

  /// The cadence used while a backlog remains.
  final Duration catchUpInterval;

  final DelayedSchedule _schedule;
  final CancelSchedule _cancel;

  Object? _handle;
  bool _running = false;

  /// Whether the armed tick is already the catch-up one, so [catchUpSoon] can
  /// be a no-op rather than pushing a near tick further out.
  bool _catchingUp = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    _arm(interval);
  }

  void stop() {
    _running = false;
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    _cancel(handle);
  }

  /// Brings the next tick forward to [catchUpInterval].
  ///
  /// For work that arrives **between** ticks: a structural layout save
  /// writes the tabs and their layout immediately but deliberately leaves the
  /// scrollback text to this timer, and without this that text would wait for
  /// whichever idle tick was already armed — up to a full [interval] away, when
  /// the backlog is known about right now.
  ///
  /// A no-op while a catch-up tick is already armed, so calling it repeatedly
  /// (a user splitting panes in a row) can never keep pushing the tick out.
  void catchUpSoon() {
    if (!_running || _catchingUp) return;
    final handle = _handle;
    // No handle means a tick is running; it re-arms itself from what it finds.
    if (handle == null) return;
    _handle = null;
    _cancel(handle);
    _arm(catchUpInterval);
  }

  void _arm(Duration delay) {
    _catchingUp = delay == catchUpInterval;
    _handle = _schedule(delay, _fire);
  }

  void _fire() {
    _handle = null;
    if (!_running) return;
    final more = onTick();
    // Re-armed only after the tick, so a slow batch can never overlap itself.
    if (_running) _arm(more ? catchUpInterval : interval);
  }

  static Object _defaultSchedule(Duration delay, void Function() callback) =>
      Timer(delay, callback);

  static void _defaultCancel(Object handle) => (handle as Timer).cancel();
}

/// Builds the autosave for the sessions controller.
///
/// Injected the same way the terminal instance factory is: a real `Timer`
/// outlives the widget tree, which trips `flutter_test`'s "no pending timers"
/// invariant, so widget tests override this with a scheduler that never fires.
typedef ScrollbackAutosaveFactory =
    ScrollbackAutosave Function({required bool Function() onTick});

final scrollbackAutosaveFactoryProvider = Provider<ScrollbackAutosaveFactory>(
  (ref) =>
      ({required onTick}) => ScrollbackAutosave(onTick: onTick),
);
