import 'agent_usage.dart';

/// Where a quota stops being background information. One pair for every
/// surface, so the chip, the meters and the fan-out cannot disagree.
const double kUsageWarningPercent = 80;
const double kUsageCriticalPercent = 95;

/// How loud a reading is, before any surface picks a colour for it.
enum UsageSeverity { ok, attention, failure, unknown }

/// The severity of a measured [percent]; [UsageSeverity.unknown] for none.
UsageSeverity usageSeverityFor(double? percent) => switch (percent) {
  null => UsageSeverity.unknown,
  >= kUsageCriticalPercent => UsageSeverity.failure,
  >= kUsageWarningPercent => UsageSeverity.attention,
  _ => UsageSeverity.ok,
};

enum UsagePaceVerdict {
  /// Not enough to say: no period, no reset, no reading, or too early.
  unknown,

  /// Spending no faster than an even rate would.
  onPace,

  /// Faster than even by no more than [kUsagePaceSlack] points.
  aheadOfPace,

  /// Faster than even by more than the slack: at this rate the limit arrives
  /// well before the reset.
  overPace,

  /// Nothing left until the reset.
  spent,
}

/// How a window is being spent, measured against an even rate across it.
class UsagePace {
  const UsagePace._(this.verdict, {this.elapsed, this.projected, this.limitAt});

  static const unknown = UsagePace._(UsagePaceVerdict.unknown);

  final UsagePaceVerdict verdict;

  /// How much of the window had passed when the reading was taken, 0–1.
  final double? elapsed;

  /// The percentage the window ends at if spending carries on at this rate.
  final double? projected;

  /// When the limit is reached at this rate — only when spending is above an
  /// even rate.
  final DateTime? limitAt;
}

/// Under this much of a window a rate is noise: 2% spent in the first minute
/// "projects" to 600%.
const double kUsagePaceMinElapsed = 0.05;

/// How many points over an even rate a window may be before it is "ahead".
const double kUsagePaceSlack = 10;

/// **The pace of [window] as of [readAt]** — the reading's own time, not the
/// clock's, because the percentage is only true then.
///
/// The window started `span` before its reset. Spending evenly, `elapsed` of
/// the window would have used `elapsed` of the quota; the projection is the
/// current rate carried to the reset. Nothing is guessed: a window without a
/// period, a reset or a reading, or one whose reset has already passed, is
/// [UsagePace.unknown].
UsagePace usagePace(UsageWindow window, DateTime readAt) {
  final percent = window.percent;
  final resetsAt = window.resetsAt;
  final span = window.span;
  if (percent == null || resetsAt == null || span == null) {
    return UsagePace.unknown;
  }
  if (span <= Duration.zero || !resetsAt.isAfter(readAt)) {
    return UsagePace.unknown;
  }
  final start = resetsAt.subtract(span);
  final passed = readAt.difference(start);
  final elapsed = (passed.inMicroseconds / span.inMicroseconds).clamp(0.0, 1.0);
  if (percent >= 100) {
    return UsagePace._(UsagePaceVerdict.spent, elapsed: elapsed);
  }
  if (elapsed < kUsagePaceMinElapsed) {
    return UsagePace._(UsagePaceVerdict.unknown, elapsed: elapsed);
  }
  final projected = percent / elapsed;
  final even = elapsed * 100;
  if (percent <= even) {
    return UsagePace._(
      UsagePaceVerdict.onPace,
      elapsed: elapsed,
      projected: projected,
    );
  }
  // Any rate above even reaches the limit before the reset if it carries on;
  // the slack separates "a little ahead" from "will run out".
  final toLimit = Duration(
    microseconds: (passed.inMicroseconds * 100 / percent).round(),
  );
  return UsagePace._(
    percent > even + kUsagePaceSlack
        ? UsagePaceVerdict.overPace
        : UsagePaceVerdict.aheadOfPace,
    elapsed: elapsed,
    projected: projected,
    limitAt: start.add(toLimit),
  );
}
