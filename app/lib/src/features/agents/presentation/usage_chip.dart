import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/usage.dart';

import '../application/usage_forecast.dart';

export 'package:agent_cli/usage.dart'
    show kUsageWarningPercent, kUsageCriticalPercent;

/// How loud the chip is. Maps to [SemanticColors], never to a raw colour, and
/// never carries the state on its own — see [UsageChipView.label].
enum UsageTone { healthy, warning, critical, muted }

/// **What the glyph claims**: a gauge is a measurement, a history clock a
/// reading with an age, a question mark nothing observed at all.
enum UsageMark {
  /// A number the current read produced, or is producing while the first
  /// answer is still in flight.
  live,

  /// A number the app has, that the current read did not confirm.
  stale,

  /// No number at all. The chip says why in its tooltip and claims nothing.
  unknown,
}

/// Everything the chip draws, resolved from one usage snapshot. A value, so the
/// thresholds and the four states can be asserted without pumping a frame.
@immutable
class UsageChipView {
  const UsageChipView({
    required this.label,
    required this.tooltip,
    required this.tone,
    this.longLabel,
    this.mark = UsageMark.live,
    this.reading,
    this.notes = const [],
    this.short,
    this.long,
  });

  /// The shorter period as a number, for a chip drawn from parts (the title
  /// bar's): the same window [label] spells. Null when nothing was measured.
  final UsageFact? short;

  /// The longer period as a number, the window [longLabel] spells.
  final UsageFact? long;

  /// The reading the words were taken from — live or remembered — for the
  /// hover card's meters. Null when nothing was observed.
  final AgentUsage? reading;

  /// The lines about the reading rather than its windows: the account, the
  /// sign-in's lifetime, the reading's age and any failure.
  final List<String> notes;

  /// The words on the chip; **always spells out the number**, because colour is
  /// a second signal. The **shorter** period when two are known.
  final String label;

  /// The longer period, drawn after [label]. Null when the reading names only
  /// one — never a placeholder, since an unread period says nothing at all.
  final String? longLabel;

  final String tooltip;
  final UsageTone tone;

  /// What the glyph may claim about the label. A glyph and not a colour, since
  /// the colour carries the quota; the age itself is in the tooltip.
  final UsageMark mark;
}

/// **One window as a number**: how much is spent, how long until it resets,
/// and whether the spending so far is on course to run it out first.
@immutable
class UsageFact {
  const UsageFact({
    required this.percent,
    required this.tone,
    this.resetsIn,
    this.onCourseToRunOut = false,
  });

  final int percent;

  /// The countdown, as [formatUsageDuration] writes it; null when the reading
  /// named no reset.
  final String? resetsIn;

  /// At this window's pace so far, it is spent before it resets (spec §4:
  /// amber when a window is on course to run out).
  final bool onCourseToRunOut;

  /// The number's own loudness: [UsageTone.warning] at least when on course
  /// to run out.
  final UsageTone tone;
}

/// What the chip should say about [usage], as of [now]: live, checking, unknown
/// or stale. [remembered] is what makes stale survive a pane switch.
UsageChipView usageChipViewFor(
  AsyncValue<AgentUsage> usage,
  DateTime now, {
  AgentUsage? remembered,
  Map<String, UsageForecast> forecasts = const {},
}) {
  final live = usage.value;
  final value = live ?? remembered;
  final error = usage.error;
  if (value == null) {
    // Nothing was observed, so nothing is claimed: no gauge, no zero, and a
    // dash that is plainly not a reading.
    return UsageChipView(
      label: error == null ? 'usage …' : 'usage —',
      tooltip: error == null ? 'Checking agent usage…' : _messageOf(error),
      tone: UsageTone.muted,
      mark: error == null ? UsageMark.live : UsageMark.unknown,
    );
  }

  // Anything not confirmed by the current read: a failed refresh, or one still
  // in flight over a number we already had.
  final mark = error != null || live == null ? UsageMark.stale : UsageMark.live;
  final worst = _tightest(value.windows);
  final age = _ago(now.difference(value.fetchedAt));
  final expiry = value.tokenExpiresAt;
  final notes = [
    if (value.email != null) value.email!,
    if (expiry != null) _expiryLine(expiry, now),
    if (mark == UsageMark.stale) 'Last checked $age' else 'Checked $age',
    if (error != null) _failureLine(error),
  ];
  final detail = [
    for (final w in value.windows) _windowLine(w, now),
    ...notes,
  ].join('\n');

  if (worst == null) {
    // A reply that measured nothing. Not an error, so muted and marked with the
    // question glyph — there is no number here for a gauge to be about.
    final headline = value.isEmpty
        ? 'No usage windows reported.'
        : 'No quota reported for this account.';
    return UsageChipView(
      label: 'usage —',
      tooltip: '$headline\n$detail',
      tone: UsageTone.muted,
      mark: UsageMark.unknown,
      reading: value,
      notes: notes,
    );
  }

  final (short, long) = _bothPeriods(value.windows, worst);
  return UsageChipView(
    label: _fact(short, now),
    longLabel: long == null ? null : _fact(long, now),
    tooltip: detail,
    // The worst number the account has, and always one of the numbers on
    // screen — the chip never colours a fact it does not spell out.
    tone: _toneFor(worst.percent),
    mark: mark,
    reading: value,
    notes: notes,
    short: _factOf(short, now, forecasts),
    long: long == null ? null : _factOf(long, now, forecasts),
  );
}

UsageFact _factOf(
  _Reading reading,
  DateTime now,
  Map<String, UsageForecast> forecasts,
) {
  final reset = reading.window.resetsAt;
  final forecast = forecasts[reading.window.label];
  // The recent pace when it says something; the average since the window
  // opened until the history to read it from has arrived.
  final onCourse = switch (forecast?.kind) {
    UsageForecastKind.runsOut ||
    UsageForecastKind.lastsUntilReset ||
    UsageForecastKind.idle => forecast!.warns(),
    UsageForecastKind.spent => true,
    _ => onCourseToRunOut(
      percent: reading.percent,
      span: reading.window.span,
      resetsAt: reset,
      now: now,
    ),
  };
  final tone = _toneFor(reading.percent);
  return UsageFact(
    percent: reading.percent.round(),
    resetsIn: reset == null ? null : formatUsageDuration(reset.difference(now)),
    onCourseToRunOut: onCourse,
    tone: onCourse && tone == UsageTone.healthy ? UsageTone.warning : tone,
  );
}

/// Whether a window [percent] spent is, at its pace so far, spent before it
/// resets. Says nothing in a window's first tenth, where one busy minute
/// would project to a run-out.
bool onCourseToRunOut({
  required double percent,
  required Duration? span,
  required DateTime? resetsAt,
  required DateTime now,
}) {
  if (span == null || resetsAt == null || span <= Duration.zero) return false;
  if (percent >= 100) return true;
  final elapsed = span - resetsAt.difference(now);
  if (elapsed < span * 0.1 || elapsed > span) return false;
  return percent * span.inSeconds / elapsed.inSeconds >= 100;
}

/// **The two periods the chip draws**, shortest then longest, chosen by
/// [UsageWindow.span] — ordering by the countdown would swap them every week.
(_Reading, _Reading?) _bothPeriods(List<UsageWindow> windows, _Reading worst) {
  Duration? shortest;
  Duration? longest;
  for (final window in windows) {
    final span = window.span;
    // A window nothing measured cannot fill a slot: a slot is a number, and
    // this one has none. It is still named in the tooltip.
    if (span == null || window.percent == null) continue;
    if (shortest == null || span < shortest) shortest = span;
    if (longest == null || span > longest) longest = span;
  }
  if (shortest == null || shortest == longest) return (worst, null);
  final short = _tightest(windows.where((w) => w.span == shortest));
  final long = _tightest(windows.where((w) => w.span == longest));
  if (short == null || long == null) return (worst, null);
  if (worst.percent > short.percent && worst.percent > long.percent) {
    return (worst, null);
  }
  return (short, long);
}

/// One window as the chip says it: the number, and how long until it resets.
String _fact(_Reading reading, DateTime now) {
  final reset = reading.window.resetsAt;
  return reset == null
      ? '${reading.percent.round()}%'
      : '${reading.percent.round()}% · '
            '${formatUsageDuration(reset.difference(now))}';
}

/// A window **and the reading it carries** — [UsageWindow.percent] is nullable,
/// and everything downstream of here is about a number.
typedef _Reading = ({UsageWindow window, double percent});

/// The window nearest its limit **among those that carry a reading**. Null when
/// nothing was measured, which is a different answer from zero.
_Reading? _tightest(Iterable<UsageWindow> windows) {
  _Reading? tightest;
  for (final window in windows) {
    final percent = window.percent;
    if (percent == null) continue;
    if (tightest == null || percent > tightest.percent) {
      tightest = (window: window, percent: percent);
    }
  }
  return tightest;
}

UsageTone _toneFor(double percent) => switch (percent) {
  >= kUsageCriticalPercent => UsageTone.critical,
  >= kUsageWarningPercent => UsageTone.warning,
  _ => UsageTone.healthy,
};

String _windowLine(UsageWindow window, DateTime now) {
  final percent = window.percent;
  // A window the endpoint named and measured nothing for. Said in words, so the
  // one row of the tooltip that would otherwise be a number is plainly not one.
  if (percent == null) return '${window.label} · $kUsageNoQuotaReported';
  final reset = window.resetsAt;
  final resets = reset == null
      ? ''
      : ' · resets in ${formatUsageDuration(reset.difference(now))}'
            ' (${formatResetClock(reset, now)})';
  return '${window.label} · ${percent.round()}%$resets';
}

/// **When the sign-in behind this reading lapses**, shaped like a window's
/// reset. Its own line, because it is emphatically not a quota reset.
String _expiryLine(DateTime when, DateTime now) {
  final left = when.difference(now);
  return left <= Duration.zero
      ? 'Sign-in expired — run the agent once to refresh it'
      : 'Sign-in expires in ${formatUsageDuration(left)}'
            ' (${formatResetClock(when, now)})';
}

String _messageOf(Object error) =>
    error is UsageException ? error.message : '$error';

/// The one line the tooltip gives a failure that did not cost us the number. A
/// rate limit already says what it is doing, so a prefix would bury that.
String _failureLine(Object error) =>
    error is UsageException && error.kind == UsageFailureKind.rateLimited
    ? error.message
    : 'Refresh failed: ${_messageOf(error)}';

String _ago(Duration since) => since < const Duration(minutes: 1)
    ? 'just now'
    : '${formatUsageDuration(since)} ago';

/// The clock time [when] falls at. **`toLocal()` is the whole correctness**: a
/// `Z` string parses to UTC and Codex's epoch seconds parse to local.
String formatResetClock(DateTime when, DateTime now) {
  final local = when.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return clock;
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${names[local.weekday - 1]} $clock';
}

/// A countdown the width of a status bar: `2h11m`, `45m`, `3d4h`, `now`.
String formatUsageDuration(Duration span) {
  if (span <= Duration.zero) return 'now';
  if (span.inDays >= 1) {
    final hours = span.inHours - span.inDays * 24;
    return hours == 0 ? '${span.inDays}d' : '${span.inDays}d${hours}h';
  }
  if (span.inHours >= 1) {
    final minutes = span.inMinutes - span.inHours * 60;
    return minutes == 0 ? '${span.inHours}h' : '${span.inHours}h${minutes}m';
  }
  return '${span.inMinutes}m';
}
