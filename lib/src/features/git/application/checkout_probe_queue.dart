import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a row's git probe waits before it may spawn: a frame, because a probe
/// reached from the build phase charges the synchronous half of its ask to it.
final probeGateProvider = Provider<Future<void> Function()>(
  (ref) => () => SchedulerBinding.instance.endOfFrame,
);

/// How many git probes may run at once across every visible row. Four: two rows
/// at their natural width, against the twenty-eight an unbounded pane reached.
const int kCheckoutProbeConcurrency = 4;

/// Gates a checkout's git probes so a row's facts arrive after the frame that
/// drew the row, and so no more than [kCheckoutProbeConcurrency] run at once.
/// One queue for the whole app: it owns *when* and *how many*, never *what*.
class CheckoutProbeQueue {
  CheckoutProbeQueue({
    required this.gate,
    this.concurrency = kCheckoutProbeConcurrency,
  }) : assert(concurrency > 0);

  /// What every probe waits for before it may spawn anything.
  final Future<void> Function() gate;

  /// The most probes allowed to be running together. See
  /// [kCheckoutProbeConcurrency] for why it is what it is.
  final int concurrency;

  int _running = 0;

  /// Probes that have passed the gate and are waiting for a slot. FIFO, so the
  /// pane fills from the top rather than from the last row to ask.
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// Runs [probe] once the gate has opened and a slot is free — gate first, and
  /// nothing inside [probe] may re-enter this queue or the slots deadlock.
  Future<T> run<T>(Future<T> Function() probe) async {
    await gate();
    await _acquire();
    try {
      return await probe();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_running < concurrency) {
      _running++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void _release() {
    // The slot is handed straight to the next in line rather than decremented
    // and re-taken, so a burst cannot slip past a probe that has been waiting.
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    _running--;
  }
}

/// The queue every Explorer row's git probe passes through. Not `autoDispose`:
/// a per-row queue would bound each row at four and the pane at nothing.
final checkoutProbeQueueProvider = Provider<CheckoutProbeQueue>(
  (ref) => CheckoutProbeQueue(gate: ref.watch(probeGateProvider)),
);
