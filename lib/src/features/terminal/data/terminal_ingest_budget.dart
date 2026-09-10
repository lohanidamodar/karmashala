import '../domain/ingest_tier.dart';

/// Bytes the **active** pane may decode per refill, all to itself. Deliberately
/// the old per-pane cap, so a single visible pane behaves exactly as it did
/// before there was a budget: N = 1 is the same code path, same numbers.
const int kIngestHotReserveBytes = 256 * 1024;

/// Bytes **every hidden pane put together** may decode per refill. Per-pane
/// caps let a hundred panes offer 25 MiB of VT parsing to one frame.
const int kIngestWarmPoolBytes = 64 * 1024;

/// How often the pool is refilled — one frame at 60 Hz.
const Duration kIngestRefillInterval = Duration(milliseconds: 16);

/// A monotonically increasing time source, injected so tests drive refills
/// exactly rather than by waiting.
typedef IngestClock = Duration Function();

/// One frame's worth of VT parsing, shared by every pane. **One global budget,
/// not a watchdog per pane**: no pane knows what the other ninety-nine do.
class TerminalIngestBudget {
  TerminalIngestBudget({
    this.hotReserveBytes = kIngestHotReserveBytes,
    this.warmPoolBytes = kIngestWarmPoolBytes,
    this.refillInterval = kIngestRefillInterval,
    IngestClock? clock,
  }) : _clock = clock ?? _defaultClock {
    _refilledAt = _clock();
    _pool = warmPoolBytes;
  }

  /// What one hot pane may take per refill, reserved.
  final int hotReserveBytes;

  /// What all warm panes together may take per refill.
  final int warmPoolBytes;

  final Duration refillInterval;
  final IngestClock _clock;

  late Duration _refilledAt;
  late int _pool;
  int _refills = 0;

  /// Bytes granted since construction, by tier. Diagnostics, and what the
  /// tests assert on — a budget that silently stopped applying would otherwise
  /// look exactly like one that was never needed.
  final Map<IngestTier, int> granted = {
    IngestTier.hot: 0,
    IngestTier.warm: 0,
    IngestTier.cold: 0,
  };

  /// How many times the pool has been refilled; one per elapsed interval in
  /// which anything asked for bytes.
  int get refills => _refills;

  /// Bytes still in the shared warm pool this interval.
  int get warmPoolRemaining => _pool;

  /// How many of the [wanted] bytes a pane in [tier] may decode right now. Zero
  /// is a legitimate answer and means "not this interval" — the caller keeps the
  /// bytes queued and asks again; it is never a signal to drop anything.
  int take(IngestTier tier, int wanted) {
    if (wanted <= 0) return 0;
    _maybeRefill();
    final allowed = switch (tier) {
      // The reserve is per-pane and per-interval, and does not draw on the
      // pool: the user is waiting on this one.
      IngestTier.hot => wanted < hotReserveBytes ? wanted : hotReserveBytes,
      IngestTier.warm => _takeFromPool(wanted),
      // A cold pane parses only enough to keep its screen readable, and that is
      // background work like any other, so it comes out of the same pool.
      IngestTier.cold => _takeFromPool(wanted),
    };
    granted[tier] = granted[tier]! + allowed;
    return allowed;
  }

  int _takeFromPool(int wanted) {
    final allowed = wanted < _pool ? wanted : _pool;
    _pool -= allowed;
    return allowed;
  }

  void _maybeRefill() {
    final now = _clock();
    if (now - _refilledAt < refillInterval) return;
    _refilledAt = now;
    _pool = warmPoolBytes;
    _refills++;
  }
}

/// One process-wide monotonic origin, matching `PtyOutputCoalescer`'s: every
/// pane must read the same clock, and the wall clock can step backwards.
final _elapsed = Stopwatch()..start();

Duration _defaultClock() => _elapsed.elapsed;

/// The budget every pane shares unless a test hands it another one.
/// Process-wide rather than a Riverpod provider because it *is* process-wide:
/// there is one UI isolate, and the thing being rationed is its frame.
final TerminalIngestBudget terminalIngestBudget = TerminalIngestBudget();
