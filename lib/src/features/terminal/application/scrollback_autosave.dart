import 'dart:async';

import 'package:riverpod/riverpod.dart';

/// How often live panes are re-snapshotted when everything is up to date.
/// Close-to-tray terminates the process without disposing the container, so
/// this is the trigger that matters: 20 s bounds the worst-case loss.
const Duration kScrollbackAutosaveInterval = Duration(seconds: 20);

/// How soon the next batch runs when the last tick left panes unsaved. A tick
/// is capped at [kScrollbackAutosaveBudget], so at the hundred-pane scale
/// target one cannot get through them all; coming back in a second drains the
/// backlog at ~8 ms per second rather than in one freeze.
const Duration kScrollbackAutosaveCatchUp = Duration(seconds: 1);

/// Most main-isolate time one autosave tick may spend — half a 60 Hz frame,
/// which is what makes a tick's cost **constant in the number of panes**.
const Duration kScrollbackAutosaveBudget = Duration(milliseconds: 8);

/// Schedules a one-shot callback, returning a handle that [CancelSchedule] can
/// stop. Injected so tests drive the policy with no real clock.
typedef DelayedSchedule =
    Object Function(Duration delay, void Function() callback);

typedef CancelSchedule = void Function(Object handle);

/// Runs [onTick] on an interval while started, coming back sooner when a tick
/// reports it left work behind. Thin on purpose — which panes are dirty is the
/// controller's — so the policy is testable without waiting 20 real seconds.
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

  /// Whether the armed tick is already the catch-up one, so [catchUpSoon] is a
  /// no-op rather than pushing a near tick further out.
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

  /// Brings the next tick forward to [catchUpInterval], for work that arrives
  /// **between** ticks — a structural save's deferred scrollback would
  /// otherwise wait out a full [interval] that is already armed.
  ///
  /// A no-op while a catch-up tick is armed, so repeated calls cannot keep
  /// pushing the tick out.
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

/// Builds the autosave for the sessions controller. Injected because a real
/// `Timer` outlives the widget tree and trips `flutter_test`'s "no pending
/// timers" invariant.
typedef ScrollbackAutosaveFactory =
    ScrollbackAutosave Function({required bool Function() onTick});

final scrollbackAutosaveFactoryProvider = Provider<ScrollbackAutosaveFactory>(
  (ref) =>
      ({required onTick}) => ScrollbackAutosave(onTick: onTick),
);
