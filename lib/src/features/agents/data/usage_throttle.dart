import 'dart:math';

import 'package:karmashala_core/util.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';

/// The periods the two endpoints' own keys name.
///
/// Not our choice and not a tuning knob: `five_hour` / `seven_day` and
/// `primary_window` / `secondary_window` are what the payloads call their
/// buckets, and [usageAskFloor] reads the request rate off them.
const Duration kUsageFiveHourWindow = Duration(hours: 5);
const Duration kUsageSevenDayWindow = Duration(days: 7);

/// How many steps a percentage has. One point of quota is one hundredth of the
/// window it is a percentage of.
const int kUsageQuotaSteps = 100;

/// **The floor under every usage request, whatever asked for it**, when the
/// payload names no window length — and the shortest floor a derived one may
/// produce.
///
/// Sixty seconds was the app's *poll interval*, and it was wrong twice over.
/// It bounded one of five triggers: the tick honoured it, while a session's
/// status moving, the chip's own click, the Settings button and the MCP tool
/// each asked unconditionally, and `agentUsageProvider.isFirstBuild` covered
/// only a pane switch. And it was a number nobody had measured, kept because
/// "we will not learn a limit by making the requests we are trying not to
/// make".
///
/// Both halves are fixed here. The floor now sits inside
/// `AgentUsageService.fetch`, so it bounds *every* path rather than one; and it
/// is derived from the payload rather than picked — see [usageAskFloor], which
/// reads three minutes off a five-hour quota because that is how long one point
/// of it takes to spend. This constant is what is left: the fallback for a
/// reply that names no period at all, and the value a derived floor is never
/// allowed below.
const Duration kUsageMinInterval = Duration(seconds: 60);

/// The longest the app waits before asking on its own while nothing is moving.
///
/// The floor says how fast the number *can* change; this says how long the app
/// will sit still once it has watched it *not* change. The ladder that reaches
/// it — the floor, doubled per unmoved reading — is the same shape as the `429`
/// backoff below and for the same reason: an account nobody is spending needs
/// no schedule at all, and the two triggers that mean it started being spent
/// again (a session's status moving, the user clicking) collapse the ladder to
/// the floor on the spot.
///
/// Bounded rather than unbounded because a reading has to be worth something
/// when the user looks. Fifteen minutes is 5% of a five-hour window, and every
/// surface says how old the reading is either way.
const Duration kUsageIdleCeiling = Duration(minutes: 15);

/// How long after a window's reset the app asks.
///
/// A request timed *at* the reset can be answered with the value from either
/// side of it. Small, because the reset is the one moment the number is known
/// to have changed and the point is to see the new one.
const Duration kUsageResetGrace = Duration(seconds: 5);

/// The first wait after a `429`, doubled per consecutive refusal.
///
/// One minute is [kUsageMinInterval]: the first thing a rate limit should buy
/// is skipping the shortest schedule the app can hold, not a quarter of an hour
/// of silence.
const Duration kUsageBackoffBase = Duration(minutes: 1);

/// The longest wait the doubling reaches: 1m → 2m → 4m → 8m → 16m.
///
/// Bounded because the user cannot see why the chip stopped moving, and a
/// number that is a quarter of an hour old is already at the edge of useful for
/// a five-hour window.
const Duration kUsageBackoffCeiling = Duration(minutes: 16);

/// How much of a wait is spread, as a fraction added on top of it.
///
/// **Only ever added.** A server that named a wait must not be asked sooner
/// than it said, so the spread is one-sided: 1m becomes 1m00s-1m15s. It matters
/// because every copy of this app that met one outage would otherwise come back
/// at the same instant — the owner's own 2026-09-04 failure was upstream and
/// self-resolving, which is exactly the shape that produces a synchronised
/// crowd on the way out of it.
const double kUsageBackoffJitter = 0.25;

/// The longest wait a server-sent `Retry-After` can buy.
///
/// The server outranks our doubling — it knows its own limit — but not without
/// limit: a malformed or absurd header must not take the quota off screen for
/// the rest of the day.
const Duration kUsageBackoffMax = Duration(hours: 1);

/// **How long the number on screen cannot have moved by a point.**
///
/// Every window in these payloads is a percentage *of a named period*, so one
/// point of it is one hundredth of that period's budget: three minutes of a
/// five-hour quota, an hour and forty minutes of a seven-day one. That bound
/// holds however much is spending it — ten panes on one account spend the same
/// hundred points as one — which is exactly why it is the right floor for an
/// app whose display is per pane and whose reading is per account.
///
/// The shortest window wins, because any window can become the one the chip
/// shows. A window whose period the payload does not name contributes nothing
/// rather than a guess, and a reply that names none at all falls back to
/// [kUsageMinInterval].
///
/// It is a bound on the **quota**, not on the pixels: a percentage sitting on a
/// rounding boundary can flip the displayed integer with a fraction of a point.
/// That is disclosed rather than hidden — every surface draws the reading with
/// its age — and it is the trade this floor makes on purpose, because asking
/// three times as often to catch a rounding boundary is what the rate limit was
/// refusing.
Duration usageAskFloor(AgentUsage usage) {
  Duration? shortest;
  for (final window in usage.windows) {
    final span = window.span;
    if (span == null || span <= Duration.zero) continue;
    if (shortest == null || span < shortest) shortest = span;
  }
  if (shortest == null) return kUsageMinInterval;
  final floor = Duration(
    microseconds: shortest.inMicroseconds ~/ kUsageQuotaSteps,
  );
  return floor < kUsageMinInterval ? kUsageMinInterval : floor;
}

/// Whether anything in the account's quota moved between two readings.
///
/// Every window, not just the tightest: the chip shows one number, but a
/// seven-day figure creeping while the five-hour one stands still is still an
/// account being spent, and the schedule is about the account.
bool usageMoved(AgentUsage? previous, AgentUsage current) {
  if (previous == null) return true;
  if (previous.windows.length != current.windows.length) return true;
  for (var i = 0; i < current.windows.length; i++) {
    if (previous.windows[i].percent != current.windows[i].percent) return true;
  }
  return false;
}

/// One quota, whoever asks about it.
///
/// Usage belongs to the `(agent, environment)` pair rather than to an
/// installation: two installs of one CLI in one environment spend the same
/// quota, so they share a reading, a rate limit and a backoff. The fan-out
/// strip already groups its rows this way, and it is what lets a chip per pane
/// cost one request per account.
String usageAccountKey(AgentInstallation installation) =>
    usageAccountKeyOf(installation.agentId, installation.environmentId);

/// [usageAccountKey] from the two fields, for a caller holding them loose.
String usageAccountKeyOf(String agentId, String environmentId) =>
    '$agentId@$environmentId';

/// A refusal in force: how long is left, what kind it was, and the sentence
/// that says so. Kept whole so a surface can explain a wait it did not witness.
class UsagePause {
  const UsagePause({
    required this.wait,
    required this.kind,
    required this.reason,
  });

  final Duration wait;
  final UsageFailureKind kind;

  /// The vendor's own failure, in one sentence, without the wait appended —
  /// the wait is recomputed whenever it is drawn so a countdown stays true.
  final String reason;
}

/// **What the app remembers between usage lookups**: the last reading of each
/// account, when that account is next worth asking about, and how long the
/// vendor told us to wait before asking again.
///
/// It exists because both halves of a rate limit were unhandled. Every trigger
/// — the poll, a pane switch, the settings button, a fan-out dialog — used to
/// mean an unconditional request, and a `429` was treated as an ordinary
/// failure, so the app answered a rate limit by asking again at exactly the
/// rate that caused it. And because the reading lived only inside one
/// `autoDispose` provider, the first failure after a pane switch left the chip
/// with nothing to show even though a number had been read seconds earlier.
///
/// Three rules, and they are the whole class:
///
/// * **A reading is worth showing after the fetch that produced it.** It is
///   kept per account and handed back with its own `fetchedAt`, so every
///   surface can say how old it is. Nothing here ever invents a timestamp.
/// * **No request inside the floor, whatever asked.** [rememberedIfFresh] is
///   consulted by `AgentUsageService.fetch` itself rather than by one of its
///   callers, so the floor is a property of the service and not of whoever
///   remembered to check. The floor comes from the payload — [usageAskFloor].
/// * **A refusal is a wait, not a failure to retry through.** Only `429` arms
///   it — an expired token is fixed by the user and must recover on the next
///   tick, and an unreachable endpoint costs the vendor nothing.
class UsageThrottle {
  UsageThrottle({
    required this.clock,
    this.base = kUsageBackoffBase,
    this.ceiling = kUsageBackoffCeiling,
    this.idleCeiling = kUsageIdleCeiling,
    double Function()? jitter,
  }) : _jitter = jitter ?? Random().nextDouble;

  final Clock clock;

  final Duration base;
  final Duration ceiling;

  /// The cap on the idle ladder — [kUsageIdleCeiling]. Injected so a test can
  /// pin how far the doubling is allowed to go.
  final Duration idleCeiling;

  /// A fraction in `[0, 1)`, spread over [kUsageBackoffJitter] of the wait.
  /// Injected so a test can pin the schedule exactly; the default is random.
  final double Function() _jitter;

  final _entries = <String, _Account>{};
  final _limits = <String, _RateLimit>{};

  /// The last reading for this account, however old. Null if none was ever
  /// taken in this run.
  AgentUsage? remembered(AgentInstallation installation) =>
      _entries[usageAccountKey(installation)]?.usage;

  /// The last reading, but only while it is younger than this account's floor —
  /// a reading recent enough that asking again cannot buy a point of quota.
  ///
  /// **The one gate every request passes.** Before the first reading there is
  /// nothing to serve and the fetch goes ahead, which is why the first ask of a
  /// run is always a real one.
  AgentUsage? rememberedIfFresh(AgentInstallation installation) {
    final entry = _entries[usageAccountKey(installation)];
    if (entry == null) return null;
    final age = clock.nowUtc().difference(entry.usage.fetchedAt);
    return age.isNegative || age < entry.floor ? entry.usage : null;
  }

  /// This account's floor — how long a reading stands in for a fresh one.
  ///
  /// Exposed so a surface can say why a refresh returned the number it already
  /// had, and so a test can assert the schedule rather than infer it.
  Duration floorFor(AgentInstallation installation) =>
      _entries[usageAccountKey(installation)]?.floor ?? kUsageMinInterval;

  /// How long until this account is worth asking about **on the app's own
  /// initiative** — what the refresh timer arms itself at.
  ///
  /// Longer than the floor whenever the last two readings were identical: an
  /// account nobody is spending is asked about less and less often, up to
  /// [idleCeiling]. Never later than a window's own reset, which is the one
  /// moment the number is known to change. [Duration.zero] means *now*, and is
  /// also the answer before any reading exists.
  Duration dueIn(AgentInstallation installation) =>
      dueInForKey(usageAccountKey(installation));

  /// [dueIn] for a caller that holds the account key rather than one of its
  /// installations — the refresh policy, which is keyed by account precisely so
  /// that several panes on one account share one timer.
  Duration dueInForKey(String key) {
    final entry = _entries[key];
    if (entry == null) return Duration.zero;
    final left = entry.askAt.difference(clock.nowUtc());
    return left.isNegative ? Duration.zero : left;
  }

  /// The refusal in force for this account, or null if it may ask now.
  ///
  /// Recomputed from the clock on every call, so a countdown drawn twenty
  /// seconds later is twenty seconds shorter rather than the number that was
  /// true when the vendor said no.
  UsagePause? pauseFor(AgentInstallation installation) {
    final limit = _limits[usageAccountKey(installation)];
    if (limit == null) return null;
    final left = limit.until.difference(clock.nowUtc());
    return left > Duration.zero
        ? UsagePause(wait: left, kind: limit.kind, reason: limit.reason)
        : null;
  }

  /// A reading arrived: remember it with the schedule it implies, and forget
  /// the limit it cleared.
  void recordSuccess(AgentInstallation installation, AgentUsage usage) {
    final key = usageAccountKey(installation);
    final previous = _entries[key];
    final floor = usageAskFloor(usage);
    // Movement resets the ladder to the floor; an unmoved reading doubles what
    // the app waited for last time. The first reading of a run has nothing to
    // compare against and therefore starts at the floor.
    final due = usageMoved(previous?.usage, usage)
        ? floor
        : _clamp(previous!.due * 2, floor, idleCeiling);
    _entries[key] = _Account(
      usage: usage,
      floor: floor,
      due: due,
      askAt: _askAt(usage, floor: floor, due: due),
    );
    _limits.remove(key);
  }

  /// When to ask next: the ladder, pulled in by any window reset that lands
  /// sooner. A reset already past — a reading old enough that its own window
  /// has turned over — cannot pull the ask inside the floor.
  DateTime _askAt(
    AgentUsage usage, {
    required Duration floor,
    required Duration due,
  }) {
    var at = usage.fetchedAt.add(due);
    final earliest = usage.fetchedAt.add(floor);
    for (final window in usage.windows) {
      final reset = window.resetsAt;
      if (reset == null) continue;
      final after = reset.add(kUsageResetGrace);
      if (after.isAfter(earliest) && after.isBefore(at)) at = after;
    }
    return at;
  }

  /// The vendor said no, in a way that means *stop asking* — a `429` or a
  /// `5xx`. Returns the wait this account is now holding.
  ///
  /// [retryAfter] is the server's own `Retry-After`, and it wins: it is the one
  /// number in this exchange that is not a guess. Absent, the wait doubles from
  /// [base] to [ceiling] per consecutive refusal. Either way it is spread by up
  /// to [kUsageBackoffJitter], upwards only.
  UsagePause recordRefusal(
    AgentInstallation installation, {
    required UsageFailureKind kind,
    required String reason,
    Duration? retryAfter,
  }) {
    final key = usageAccountKey(installation);
    final attempts = (_limits[key]?.attempts ?? 0) + 1;
    final wait = _clamp(
      _spread(retryAfter ?? _doubled(attempts)),
      Duration.zero,
      kUsageBackoffMax,
    );
    _limits[key] = _RateLimit(
      until: clock.nowUtc().add(wait),
      attempts: attempts,
      kind: kind,
      reason: reason,
    );
    return UsagePause(wait: wait, kind: kind, reason: reason);
  }

  Duration _spread(Duration wait) =>
      wait + wait * (kUsageBackoffJitter * _jitter().clamp(0, 1));

  /// Drops everything known about one account, so the next ask is a real one.
  /// Used by the tests that need a clean slate; nothing in the app calls it.
  void forget(AgentInstallation installation) {
    final key = usageAccountKey(installation);
    _entries.remove(key);
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

/// One account's last reading and the schedule it implies.
class _Account {
  const _Account({
    required this.usage,
    required this.floor,
    required this.due,
    required this.askAt,
  });

  final AgentUsage usage;

  /// The shortest time in which this account's quota can move by a point —
  /// [usageAskFloor] of [usage]. No request is served inside it.
  final Duration floor;

  /// What the app waited for on its own before this reading; the value the idle
  /// ladder doubles.
  final Duration due;

  /// The moment the refresh timer aims at: [due] after the reading, pulled in
  /// by a window reset.
  final DateTime askAt;
}

class _RateLimit {
  const _RateLimit({
    required this.until,
    required this.attempts,
    required this.kind,
    required this.reason,
  });

  final DateTime until;

  /// Consecutive refusals, which is what the doubling counts. Reset by any
  /// success, so a limit that lifts costs the next one nothing.
  final int attempts;

  final UsageFailureKind kind;
  final String reason;
}
