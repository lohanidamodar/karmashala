import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:riverpod/riverpod.dart';

import 'agent_usage_providers.dart';
import 'usage_history.dart';

/// How far back the recent rate looks. Short on purpose: the question is how
/// fast the quota is going *now*, not on average since the window opened.
const Duration kUsageForecastLookback = Duration(minutes: 60);

/// The narrower look the band's second rate is taken over.
const Duration kUsageForecastShortLookback = Duration(minutes: 30);

/// How far back a flat stretch is looked for. The server reads less often
/// while a quota does not move, so an idle hour may hold one reading.
const Duration kUsageForecastIdleLookback = Duration(hours: 3);

/// Fewer readings than this in [kUsageForecastLookback], or a span shorter
/// than [kUsageForecastMinSpan], is "not enough data" — never a guess.
const int kUsageForecastMinReadings = 3;
const Duration kUsageForecastMinSpan = Duration(minutes: 15);

/// Below this rate, in points an hour, a window is idle rather than "lasting".
const double kUsageForecastIdleRate = 0.5;

/// A run-out at least this long before the reset is a warning.
const Duration kUsageForecastWarnMargin = Duration(minutes: 15);

/// What the recent pace says about one window.
enum UsageForecastKind {
  /// The window carries no percentage (an ACP account, a tier list).
  notMeasured,

  /// Too few recent readings to name a rate.
  notEnoughData,

  /// Readings, and nothing spent in them.
  idle,

  /// At this pace the reset comes first.
  lastsUntilReset,

  /// At this pace the limit comes first, or no reset is known.
  runsOut,

  /// Nothing left until the reset.
  spent,
}

/// **One window's forecast at its recent pace.** The one answer every usage
/// surface draws — the chip, the popover, the Usage tab, the glance — so they
/// never disagree.
@immutable
class UsageForecast {
  const UsageForecast({
    required this.kind,
    required this.windowLabel,
    this.percent,
    this.readAt,
    this.resetsAt,
    this.ratePerHour,
    this.runsOutAt,
    this.earliestRunOut,
    this.latestRunOut,
    this.lowRatePerHour,
    this.highRatePerHour,
  });

  final UsageForecastKind kind;
  final String windowLabel;

  /// The reading the forecast starts from, and when it was taken.
  final double? percent;
  final DateTime? readAt;
  final DateTime? resetsAt;

  /// Points an hour over the recent readings, smoothed by a least-squares fit.
  final double? ratePerHour;

  /// The band around [ratePerHour]: the slower and faster rates the recent
  /// readings allow.
  final double? lowRatePerHour;
  final double? highRatePerHour;

  /// When the limit arrives at [ratePerHour], and at the band's edges.
  final DateTime? runsOutAt;
  final DateTime? earliestRunOut;
  final DateTime? latestRunOut;

  /// It runs out at least [margin] before its reset: the warning.
  bool warns({Duration margin = kUsageForecastWarnMargin}) {
    final out = runsOutAt;
    final reset = resetsAt;
    if (kind != UsageForecastKind.runsOut || out == null || reset == null) {
      return false;
    }
    return reset.difference(out) >= margin;
  }

  /// Where the line ends: the run-out when it comes first, else the reset.
  DateTime? get end {
    final reset = resetsAt;
    final out = runsOutAt;
    if (out == null) return reset;
    if (reset == null) return out;
    return out.isBefore(reset) ? out : reset;
  }

  /// The percentage [rate] reaches at [at], capped at the limit.
  double valueAt(DateTime at, {double? rate}) {
    final from = percent ?? 0;
    final r = rate ?? ratePerHour ?? 0;
    final from0 = readAt;
    if (from0 == null) return from;
    final hours =
        at.difference(from0).inMicroseconds / Duration.microsecondsPerHour;
    return math.min(100, from + r * math.max(0, hours));
  }

  @override
  bool operator ==(Object other) =>
      other is UsageForecast &&
      other.kind == kind &&
      other.windowLabel == windowLabel &&
      other.percent == percent &&
      other.readAt == readAt &&
      other.resetsAt == resetsAt &&
      other.ratePerHour == ratePerHour &&
      other.runsOutAt == runsOutAt;

  @override
  int get hashCode => Object.hash(
    kind,
    windowLabel,
    percent,
    readAt,
    resetsAt,
    ratePerHour,
    runsOutAt,
  );
}

/// **[window]'s forecast at its recent pace**, from [samples] of its history
/// (any window's; the others are ignored) and the reading taken at [readAt].
///
/// Only the readings since the window last reset count, and only the last
/// [kUsageForecastLookback] of them: a least-squares rate over those, so one
/// jumpy reading does not swing it. Too few readings say so; a flat stretch is
/// idle, not "never runs out".
UsageForecast usageForecastFor(
  UsageWindow window, {
  required DateTime readAt,
  required Iterable<UsageSample> samples,
}) {
  final label = window.label;
  final percent = window.percent;
  final reset = window.resetsAt;
  if (percent == null) {
    return UsageForecast(
      kind: UsageForecastKind.notMeasured,
      windowLabel: label,
    );
  }
  UsageForecast bare(UsageForecastKind kind) => UsageForecast(
    kind: kind,
    windowLabel: label,
    percent: percent,
    readAt: readAt,
    resetsAt: reset,
  );
  if (percent >= 100) return bare(UsageForecastKind.spent);
  if (reset != null && !reset.isAfter(readAt)) {
    return bare(UsageForecastKind.notEnoughData);
  }

  final points = _currentPeriod(label, readAt, percent, samples);
  final recent = _since(points, readAt.subtract(kUsageForecastLookback));
  if (!_enough(recent)) {
    final longer = _since(points, readAt.subtract(kUsageForecastIdleLookback));
    final flat =
        longer.length >= 2 &&
        _span(longer) >= kUsageForecastMinSpan &&
        longer.last.$2 - longer.first.$2 < kUsageForecastIdleRate;
    return bare(
      flat ? UsageForecastKind.idle : UsageForecastKind.notEnoughData,
    );
  }

  final rate = _slope(recent);
  if (rate < kUsageForecastIdleRate) return bare(UsageForecastKind.idle);
  final short = _since(points, readAt.subtract(kUsageForecastShortLookback));
  final rates = [
    rate,
    if (short.length >= 2 && _span(short) >= const Duration(minutes: 10))
      math.max(0.0, _slope(short)),
  ];
  final low = math.max(0.0, math.min(rates.reduce(math.min), rate * 0.8));
  final high = math.max(rates.reduce(math.max), rate * 1.2);

  DateTime? at(double r) => r <= 0
      ? null
      : readAt.add(
          Duration(
            microseconds: ((100 - percent) / r * Duration.microsecondsPerHour)
                .round(),
          ),
        );
  final out = at(rate)!;
  return UsageForecast(
    kind: reset != null && !out.isBefore(reset)
        ? UsageForecastKind.lastsUntilReset
        : UsageForecastKind.runsOut,
    windowLabel: label,
    percent: percent,
    readAt: readAt,
    resetsAt: reset,
    ratePerHour: rate,
    lowRatePerHour: low,
    highRatePerHour: high,
    runsOutAt: out,
    earliestRunOut: at(high),
    latestRunOut: at(low),
  );
}

typedef _Point = (DateTime, double);

/// [label]'s readings since its last reset, oldest first, ending with the
/// reading itself. A fall is a reset: what came before it is another period.
List<_Point> _currentPeriod(
  String label,
  DateTime readAt,
  double percent,
  Iterable<UsageSample> samples,
) {
  final sorted = [
    for (final s in samples)
      if (s.windowLabel == label && !s.recordedAt.isAfter(readAt))
        (s.recordedAt, s.percent),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (sorted.isEmpty || sorted.last.$1 != readAt) {
    sorted.add((readAt, percent));
  }
  var start = 0;
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].$2 < sorted[i - 1].$2 - 0.5) start = i;
  }
  return sorted.sublist(start);
}

List<_Point> _since(List<_Point> points, DateTime from) => [
  for (final p in points)
    if (!p.$1.isBefore(from)) p,
];

Duration _span(List<_Point> points) =>
    points.isEmpty ? Duration.zero : points.last.$1.difference(points.first.$1);

bool _enough(List<_Point> points) =>
    points.length >= kUsageForecastMinReadings &&
    _span(points) >= kUsageForecastMinSpan;

/// Points an hour, by least squares.
double _slope(List<_Point> points) {
  final t0 = points.first.$1;
  final xs = [
    for (final p in points)
      p.$1.difference(t0).inMicroseconds / Duration.microsecondsPerHour,
  ];
  final ys = [for (final p in points) p.$2];
  final n = points.length;
  final mx = xs.reduce((a, b) => a + b) / n;
  final my = ys.reduce((a, b) => a + b) / n;
  var num = 0.0;
  var den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (xs[i] - mx) * (ys[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return den == 0 ? 0 : num / den;
}

/// The history a forecast reads, from the minute of [readAt]: one query per
/// reading, not per clock tick.
({String account, DateTime from}) usageForecastQuery(
  String accountKey,
  DateTime readAt,
) {
  final utc = readAt.toUtc();
  final minute = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
    utc.hour,
    utc.minute,
  );
  return (
    account: accountKey,
    from: minute.subtract(kUsageForecastIdleLookback),
  );
}

/// **Every window of [String] account's newest reading, forecast**, keyed by
/// window label. Empty before the server has read the account. Until the
/// history arrives each window is "not enough data".
final usageForecastsProvider = Provider.autoDispose
    .family<Map<String, UsageForecast>, String>((ref, accountKey) {
      final usage = ref.watch(accountUsageProvider(accountKey))?.usage;
      if (usage == null) return const {};
      final history =
          ref
              .watch(
                usageHistoryProvider(
                  usageForecastQuery(accountKey, usage.fetchedAt),
                ),
              )
              .value ??
          const <UsageSample>[];
      return {
        for (final window in usage.windows)
          window.label: usageForecastFor(
            window,
            readAt: usage.fetchedAt,
            samples: history,
          ),
      };
    });
