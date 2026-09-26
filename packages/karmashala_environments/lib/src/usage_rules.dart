import 'package:agent_cli/usage.dart';

/// What the usage history keeps: one row per measured window per reading,
/// skipping repeats, thinned with age. The server applies these to every
/// reading a client records; a client only turns a reading into candidate
/// samples ([usageSamplesOf]).

/// How long usage history is kept.
const Duration kUsageHistoryKeep = Duration(days: 30);

/// How long history stays at full resolution before it is thinned to hours.
const Duration kUsageHistoryFullResolution = Duration(hours: 48);

/// An unchanged window is still written this often, so a flat stretch reads as
/// measured-and-flat rather than as a gap.
const Duration kUsageHistoryHeartbeat = Duration(minutes: 30);

/// How often the history is pruned, at most.
const Duration kUsageHistoryPruneEvery = Duration(hours: 1);

/// Two resets closer than this are the same reset: Codex derives its reset
/// from "seconds from now", which drifts between readings.
const Duration _sameReset = Duration(minutes: 2);

/// [usage] as one candidate sample per measured window, to the second. A
/// window nothing measured has no place on a chart of numbers.
List<UsageSample> usageSamplesOf(String accountKey, AgentUsage usage) {
  final at = _toSecond(usage.fetchedAt);
  return [
    for (final window in usage.windows)
      if (window.percent case final percent? when percent.isFinite)
        UsageSample(
          accountKey: accountKey,
          windowLabel: window.label,
          span: window.span,
          percent: percent,
          resetsAt: window.resetsAt == null
              ? null
              : _toSecond(window.resetsAt!),
          recordedAt: at,
        ),
  ];
}

/// Whether [candidate] is worth a row after [last], the newest one of its
/// window: not a reading older than it, and not an unchanged one within the
/// heartbeat.
bool usageSampleWorthKeeping(UsageSample candidate, UsageSample? last) {
  if (!candidate.percent.isFinite) return false;
  if (last == null) return true;
  if (!candidate.recordedAt.isAfter(last.recordedAt)) return false;
  final unchanged =
      last.percent == candidate.percent &&
      _sameMoment(last.resetsAt, candidate.resetsAt);
  return !unchanged ||
      candidate.recordedAt.difference(last.recordedAt) >=
          kUsageHistoryHeartbeat;
}

bool _sameMoment(DateTime? a, DateTime? b) {
  if (a == null || b == null) return a == b;
  return a.difference(b).abs() < _sameReset;
}

DateTime _toSecond(DateTime value) {
  final utc = value.toUtc();
  return DateTime.fromMillisecondsSinceEpoch(
    utc.millisecondsSinceEpoch ~/ 1000 * 1000,
    isUtc: true,
  );
}
