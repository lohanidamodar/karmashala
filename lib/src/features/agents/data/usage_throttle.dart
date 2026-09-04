import '../../../core/util/clock.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_usage.dart';

/// **At most one usage request per account per minute**, and the interval the
/// status-bar chip's poll runs at. Re-exported by `usage_refresh_policy.dart`,
/// which owns the timer half.
///
/// Sixty seconds was reconsidered when the owner was rate limited, and kept —
/// but it now means something it did not mean before. It used to bound *one*
/// of four triggers (the tick), while a pane switch, the settings button and a
/// fan-out dialog each asked unconditionally; a user moving between panes could
/// spend requests as fast as they could click. Here it bounds them all: any ask
/// inside one interval of the last reading is served from [UsageThrottle], so
/// the number is a ceiling on requests rather than a floor.
///
/// Lengthening it instead would trade a number that is wrong by minutes for a
/// request budget nobody has measured — neither vendor documents a limit for
/// these endpoints, and we will not learn one by making the requests we are
/// trying not to make. The observed failure was a `429`, and a `429` carries its
/// own instructions; honouring them is evidence-led in a way that picking 180
/// seconds because it feels safer is not.
const Duration kUsageRefreshInterval = Duration(seconds: 60);

/// The first wait after a `429`, doubled per consecutive refusal.
///
/// One minute is the app's own poll interval: the first thing a rate limit
/// should buy is *skipping one tick*, not a quarter of an hour of silence.
const Duration kUsageBackoffBase = Duration(minutes: 1);

/// The longest wait the doubling reaches: 1m → 2m → 4m → 8m → 16m.
///
/// Bounded because the user cannot see why the chip stopped moving, and a
/// number that is a quarter of an hour old is already at the edge of useful for
/// a five-hour window.
const Duration kUsageBackoffCeiling = Duration(minutes: 16);

/// The longest wait a server-sent `Retry-After` can buy.
///
/// The server outranks our doubling — it knows its own limit — but not without
/// limit: a malformed or absurd header must not take the quota off screen for
/// the rest of the day.
const Duration kUsageBackoffMax = Duration(hours: 1);

/// One quota, whoever asks about it.
///
/// Usage belongs to the `(agent, environment)` pair rather than to an
/// installation: two installs of one CLI in one environment spend the same
/// quota, so they share a reading, a rate limit and a backoff. The fan-out
/// strip already groups its rows this way.
String usageAccountKey(AgentInstallation installation) =>
    '${installation.agentId}@${installation.environmentId}';

/// **What the app remembers between usage lookups**: the last reading of each
/// account, and how long the vendor told us to wait before asking again.
///
/// It exists because both halves of a rate limit were unhandled. Every trigger
/// — the poll, a pane switch, the settings button, a fan-out dialog — used to
/// mean an unconditional request, and a `429` was treated as an ordinary
/// failure, so the app answered a rate limit by asking again at exactly the
/// rate that caused it. And because the reading lived only inside one
/// `autoDispose` provider, the first failure after a pane switch left the chip
/// with nothing to show even though a number had been read seconds earlier.
///
/// Two rules, and they are the whole class:
///
/// * **A reading is worth showing after the fetch that produced it.** It is
///   kept per account and handed back with its own `fetchedAt`, so every
///   surface can say how old it is. Nothing here ever invents a timestamp.
/// * **A refusal is a wait, not a failure to retry through.** Only `429` arms
///   it — an expired token is fixed by the user and must recover on the next
///   tick, and an unreachable endpoint costs the vendor nothing.
class UsageThrottle {
  UsageThrottle({
    required this.clock,
    this.freshFor = kUsageRefreshInterval,
    this.base = kUsageBackoffBase,
    this.ceiling = kUsageBackoffCeiling,
  });

  final Clock clock;

  /// How long a reading may stand in for a fresh one — [kUsageRefreshInterval].
  ///
  /// Within one tick the app would not have asked again anyway, so a surface
  /// that appears in that window is served from memory instead of spending a
  /// request.
  final Duration freshFor;

  final Duration base;
  final Duration ceiling;

  final _readings = <String, AgentUsage>{};
  final _limits = <String, _RateLimit>{};

  /// The last reading for this account, however old. Null if none was ever
  /// taken in this run.
  AgentUsage? remembered(AgentInstallation installation) =>
      _readings[usageAccountKey(installation)];

  /// The last reading, but only while it is younger than [freshFor] — a
  /// reading recent enough that asking again would buy nothing.
  AgentUsage? rememberedIfFresh(AgentInstallation installation) {
    final usage = remembered(installation);
    if (usage == null) return null;
    final age = clock.nowUtc().difference(usage.fetchedAt);
    return age.isNegative || age < freshFor ? usage : null;
  }

  /// How much longer this account is holding off, or null if it may ask now.
  Duration? waitFor(AgentInstallation installation) {
    final limit = _limits[usageAccountKey(installation)];
    if (limit == null) return null;
    final left = limit.until.difference(clock.nowUtc());
    return left > Duration.zero ? left : null;
  }

  /// A reading arrived: remember it, and forget the limit it cleared.
  void recordSuccess(AgentInstallation installation, AgentUsage usage) {
    final key = usageAccountKey(installation);
    _readings[key] = usage;
    _limits.remove(key);
  }

  /// The vendor said no. Returns how long this account will now wait.
  ///
  /// [retryAfter] is the server's own `Retry-After`, and it wins: it is the one
  /// number in this exchange that is not a guess. Absent, the wait doubles from
  /// [base] to [ceiling] per consecutive refusal.
  Duration recordRateLimit(
    AgentInstallation installation, {
    Duration? retryAfter,
  }) {
    final key = usageAccountKey(installation);
    final attempts = (_limits[key]?.attempts ?? 0) + 1;
    final wait = retryAfter == null
        ? _doubled(attempts)
        : _clamp(retryAfter, Duration.zero, kUsageBackoffMax);
    _limits[key] = _RateLimit(
      until: clock.nowUtc().add(wait),
      attempts: attempts,
    );
    return wait;
  }

  /// Drops everything known about one account, so the next ask is a real one.
  /// Used by the tests that need a clean slate; nothing in the app calls it.
  void forget(AgentInstallation installation) {
    final key = usageAccountKey(installation);
    _readings.remove(key);
    _limits.remove(key);
  }

  Duration _doubled(int attempts) {
    var wait = base;
    for (var i = 1; i < attempts; i++) {
      wait *= 2;
      if (wait >= ceiling) return ceiling;
    }
    return wait > ceiling ? ceiling : wait;
  }

  Duration _clamp(Duration value, Duration low, Duration high) =>
      value < low ? low : (value > high ? high : value);
}

class _RateLimit {
  const _RateLimit({required this.until, required this.attempts});

  final DateTime until;

  /// Consecutive refusals, which is what the doubling counts. Reset by any
  /// success, so a limit that lifts costs the next one nothing.
  final int attempts;
}
