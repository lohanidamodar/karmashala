import 'dart:async';
import 'dart:collection';

/// How many directory reads one CLI-store job may have in flight.
///
/// **Two, and the axis is deliberate.** The scan's jobs are serial by
/// construction — Claude, then Codex, then Antigravity, one at a time on the
/// worker isolate — so the only place anything fans out is *inside* a job: the
/// 12 project directories of the owner's Claude store and the 663 files under
/// them, or the rollouts under Codex's date nesting. Bounding the jobs would
/// bound a one; bounding repositories would bound a number that no longer
/// drives a scan at all.
///
/// Two rather than four, which is what [kCheckoutProbeConcurrency] settled on
/// for git probes, because the two workloads saturate differently. That one
/// bounds *process creations*, where the cost is CPU on the asking thread and
/// four is "two rows at their natural width". This one bounds *walks across a
/// 9p share*, where the cost is round trips into a distribution and the two
/// backends the app actually has — the host's own disk and `\\wsl.localhost` —
/// are exactly two. Two lets a local walk overlap a share walk without ever
/// putting a second walk on the share.
///
/// **What the bound protects, and what it costs.** Nothing waits on this scan:
/// it runs after the first frame, off the UI isolate, and publishes when it
/// lands. So a low bound costs wall-clock nobody is watching and protects the
/// share from a 663-way burst — the opposite of the trade the git probes made,
/// where the owner felt the added latency because rows on screen were waiting.
const int kStoreScanConcurrency = 2;

/// A FIFO semaphore for one store scan, and the peak it actually reached.
///
/// Same shape as `CheckoutProbeQueue`'s slots, minus the frame gate: there is
/// no frame to wait for on a worker isolate. FIFO for the same reason — a stack
/// would serve the newest directory first and finish the whole store no sooner.
class StoreScanSlots {
  StoreScanSlots({this.concurrency = kStoreScanConcurrency})
    : assert(concurrency > 0);

  /// The most reads allowed to be running together.
  final int concurrency;

  int _running = 0;
  int _peak = 0;

  /// The most reads that were ever running together. Asserted rather than
  /// timed — see `store_scan_concurrency_test.dart`.
  int get peakInFlight => _peak;

  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() work) async {
    await _acquire();
    try {
      return await work();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_running < concurrency) {
      _running++;
      if (_running > _peak) _peak = _running;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void _release() {
    // Handed straight to the next in line, so a burst cannot slip past a read
    // that has been waiting.
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    _running--;
  }
}
