import 'package:meta/meta.dart';

/// One measured quota window at one moment, as the usage history keeps it.
@immutable
class UsageSample {
  const UsageSample({
    required this.accountKey,
    required this.windowLabel,
    required this.percent,
    required this.recordedAt,
    this.span,
    this.resetsAt,
  });

  /// `usageAccountKey` — `agentId@environmentId`.
  final String accountKey;
  final String windowLabel;
  final double percent;
  final Duration? span;
  final DateTime? resetsAt;

  /// The reading's own `fetchedAt`, to the second.
  final DateTime recordedAt;

  @override
  bool operator ==(Object other) =>
      other is UsageSample &&
      other.accountKey == accountKey &&
      other.windowLabel == windowLabel &&
      other.percent == percent &&
      other.span == span &&
      other.resetsAt == resetsAt &&
      other.recordedAt == recordedAt;

  @override
  int get hashCode =>
      Object.hash(accountKey, windowLabel, percent, span, resetsAt, recordedAt);

  @override
  String toString() =>
      'UsageSample($accountKey, $windowLabel, $percent% at $recordedAt)';
}

/// How much of a window was spent on each local day: the sum of its rises.
///
/// A fall is a reset — quota coming back, not negative spending — so it adds
/// nothing, and the rise after it counts from the new, lower level. Days are
/// keyed by local midnight. Samples must belong to one window.
Map<DateTime, double> usageSpentPerDay(List<UsageSample> samples) {
  final sorted = [...samples]
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  final spent = <DateTime, double>{};
  for (var i = 1; i < sorted.length; i++) {
    final rise = sorted[i].percent - sorted[i - 1].percent;
    final local = sorted[i].recordedAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    spent[day] = (spent[day] ?? 0) + (rise > 0 ? rise : 0);
  }
  return spent;
}
