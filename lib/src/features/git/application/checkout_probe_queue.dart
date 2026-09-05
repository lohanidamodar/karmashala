import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a row's git probe waits before it is allowed to spawn anything.
///
/// **A frame, because a process creation is charged to the frame that asks for
/// it.** `Process.run` looks asynchronous and is not: `CreateProcessW` runs on
/// the calling thread before the future is returned, which is why a 60 s
/// profile of this app names `RtlCreateUnicodeString` (4.60%) and
/// `NtCreateUserProcess` (2.02%) among its top Dart CPU leaves, with
/// `_Utf8Decoder.decode16` and `_StringBase._interpolate` under them — spawning
/// git and reading its output, attributed to the isolate that asked. And
/// `checkoutDeliveryProvider` is created *during the build phase* of the frame
/// that draws a row, reaching `Process.run` before its first `await` — so a
/// pane of ten rows spawned ten processes inside one build phase and the rest
/// in the microtasks right behind it, measured as
/// `phases=[persistentCallbacks, idle]` in `checkout_scale_cost_test.dart`.
/// Awaiting this first makes that `phases=[idle]`.
///
/// **A frame rather than a bare `await`**, and the difference is only visible
/// for a probe that starts *outside* a frame — a workspace mutation, which
/// arrives from a session starting or stopping rather than from a build. A
/// microtask would spawn before the next frame was drawn and delay it; this
/// waits for the frame first. Inside a frame the two are equivalent, because a
/// post-frame callback registered during the build runs at the end of that same
/// frame. `checkout_scale_cost_test.dart` tells them apart by draining
/// microtasks after a mutation and expecting nothing to have spawned.
///
/// A frame and not a delay, for the reason `frameYieldProvider` gives at
/// greater length: there is nothing to wait *for*, so a fixed `Future.delayed`
/// would be a guess at somebody else's CPU — and a pending timer is what a
/// widget test complains about at the end. And awaited per probe rather than
/// latched once at start-up, because a mutation re-reads every visible row and
/// deserves the same treatment the first frame got.
///
/// A provider so a headless test has something to override. The default is
/// what the app always uses; tests neutralise it through `headlessProbeGate`
/// because a `ProviderContainer` with no widget tree pumps no frames, and an
/// un-pumped `endOfFrame` never completes.
///
/// **What this gate is still for, now that the spawn has moved.** Everything
/// above described a `Process.run` reached from the build phase; the creation
/// itself no longer happens on this isolate at all — `LocalCommandRunner` and
/// `WslCommandRunner` hand the request to a worker isolate, and
/// `core/process/process_spawner.dart` says why. What is left on the frame's
/// thread is the request, the port hop and the decoding of what comes back,
/// which is real but is not the two hundred milliseconds a `wsl.exe` cost.
/// The gate stays because the *rest* of that work still belongs after the
/// frame rather than inside it, and because deferring the ask is what keeps a
/// pane of rows from filling the worker's queue during a build. The
/// measurements above are the ones that were taken; they are not re-taken
/// here.
final probeGateProvider = Provider<Future<void> Function()>(
  (ref) => () => SchedulerBinding.instance.endOfFrame,
);

/// How many git probes may be running at once, across every visible row.
///
/// **Measured, before there was a bound at all**, by counting overlapping
/// subprocesses in `checkout_scale_cost_test.dart`'s `a full pane of rows`
/// scene — a session in every checkout, so the pane draws as many rows as it
/// fits:
///
/// ```txt
/// checkouts   1    10    69
/// peak        2    20    28
/// ```
///
/// Twenty-eight `git` processes alive together, each one a `\\wsl.localhost`
/// round trip, to fill in ten branch chips. Nothing was throttling them: the
/// frame gate above decides *when* a probe may start and says nothing about
/// how many may start at once, so every row's fan-out was released into the
/// same microtask queue the moment the frame ended.
///
/// **Four**, and the two numbers it sits between are what pick it:
///
/// * One checkout's five probes are at most **two** wide. `status`, then
///   `remote get-url`, then `origin/HEAD` are each waiting on the answer
///   before them; only `rev-list` and `diff --numstat` are started together,
///   because they are the one pair that does not need each other's answer. So
///   a bound of 1 would stretch a single row from four round trips to five,
///   and a bound of 2 would let exactly one row make progress while every
///   other row on screen waited for it to finish entirely.
/// * Four is therefore **two rows at their natural width** — which is what a
///   user watching the top of a pane fill in actually sees — while capping the
///   `CreateProcessW` burst charged to the isolate at four instead of
///   twenty-eight.
///
/// That last clause is now the *worker* isolate's burst rather than the UI
/// isolate's, and the bound is worth keeping for the reason it was measured
/// for: twenty-eight `git` processes alive together across `\\wsl.localhost`
/// is a load on the share and on the machine, whichever isolate asked for
/// them. What the bound never did is fix the stall — a limit on how many
/// probes are *in flight* cannot help when every creation passes through the
/// asking isolate one at a time regardless.
///
/// Counted rather than timed, and a count rather than a duration for the
/// reason `checkout_scale_cost_test.dart` gives at length: milliseconds on a
/// shared machine are noise, and the deterministic half of the shape is how
/// many processes exist at once.
const int kCheckoutProbeConcurrency = 4;

/// Gates a checkout's git probes so a row's facts arrive after the frame that
/// drew the row, not inside it — and so no more than
/// [kCheckoutProbeConcurrency] of them exist at a time.
///
/// One queue for the whole app, held by [checkoutProbeQueueProvider]. It owns
/// *when* and *how many*, never *what*: every caller asks git exactly what it
/// asked before.
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

  /// Probes that have passed the gate and are waiting for a slot, in the order
  /// they asked.
  ///
  /// **FIFO, so the pane fills from the top.** A stack would serve the last
  /// row to ask first, which on screen means the rows the user is looking at
  /// are the last to get a branch chip — the same total work arranged to look
  /// slower.
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// Runs [probe] once the gate has opened and a slot is free.
  ///
  /// The gate is awaited before [probe] is *called*, not before its result is
  /// awaited, which is the whole point: the synchronous prefix of a git call —
  /// the `CreateProcessW` — is what has to land outside the frame. The slot is
  /// taken after the gate for the same reason in the other direction: a probe
  /// holding a slot while it waits for a frame is a slot no other row can use
  /// for the whole of that frame.
  ///
  /// **Nothing awaited inside [probe] may itself pass through this queue.** A
  /// probe that waited on another probe would hold its slot while it did, and
  /// [concurrency] such probes would hold every slot waiting for a probe that
  /// can never get one. No caller nests today: `checkoutDeliveryProvider` runs
  /// its five as independent leaves, and `worktreeDeliveryProvider` awaits the
  /// two checkout readings it composes *outside* any probe of its own.
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

/// The queue every Explorer row's git probe passes through.
///
/// Not `autoDispose`: it is a scheduling policy rather than a reading, and it
/// has to be the *same* queue for every row or it decides nothing — a
/// per-row queue would bound each row at four and the pane at nothing.
final checkoutProbeQueueProvider = Provider<CheckoutProbeQueue>(
  (ref) => CheckoutProbeQueue(gate: ref.watch(probeGateProvider)),
);
