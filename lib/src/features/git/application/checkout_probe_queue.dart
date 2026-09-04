import 'dart:async';

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
final probeGateProvider = Provider<Future<void> Function()>(
  (ref) => () => SchedulerBinding.instance.endOfFrame,
);

/// Gates a checkout's git probes so a row's facts arrive after the frame that
/// drew the row, not inside it.
///
/// One queue for the whole app, held by [checkoutProbeQueueProvider]. It owns
/// *when*, never *what*: every caller asks git exactly what it asked before.
class CheckoutProbeQueue {
  CheckoutProbeQueue({required this.gate});

  /// What every probe waits for before it may spawn anything.
  final Future<void> Function() gate;

  /// Runs [probe] once the gate has opened.
  ///
  /// The gate is awaited before [probe] is *called*, not before its result is
  /// awaited, which is the whole point: the synchronous prefix of a git call —
  /// the `CreateProcessW` — is what has to land outside the frame.
  Future<T> run<T>(Future<T> Function() probe) async {
    await gate();
    return probe();
  }
}

/// The queue every Explorer row's git probe passes through.
///
/// Not `autoDispose`: it is a scheduling policy rather than a reading, and it
/// has to be the *same* queue for every row or it decides nothing.
final checkoutProbeQueueProvider = Provider<CheckoutProbeQueue>(
  (ref) => CheckoutProbeQueue(gate: ref.watch(probeGateProvider)),
);
