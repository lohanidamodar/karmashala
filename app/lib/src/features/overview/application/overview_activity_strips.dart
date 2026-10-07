import 'package:flutter/foundation.dart' show immutable;
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../timeline/application/timeline_controller.dart';
import '../timeline/domain/timeline_model.dart';

/// How far back the strips and the heartbeat look.
const Duration kOverviewWindow = Duration(hours: 2);

/// How far before the window the log is read, so a turn that began earlier
/// is drawn from the window's start rather than missed.
const Duration _kCarriedIn = Duration(hours: 12);

/// The heartbeat's buckets across [kOverviewWindow].
const int kOverviewBuckets = 60;

/// The last two hours of the activity log: each session's spans, and how
/// many sessions were working and waiting in each bucket.
@immutable
class OverviewActivityModel {
  const OverviewActivityModel({
    required this.from,
    required this.to,
    required this.spans,
    required this.working,
    required this.waiting,
    this.recorded = true,
  });

  /// The log could not be read: nothing is drawn, and that is said.
  static final unrecorded = OverviewActivityModel(
    from: DateTime.utc(0),
    to: DateTime.utc(0),
    spans: const {},
    working: const [],
    waiting: const [],
    recorded: false,
  );

  final DateTime from;
  final DateTime to;
  final Map<String, List<TimelineSpan>> spans;
  final List<int> working;
  final List<int> waiting;
  final bool recorded;

  /// Agent time worked in the window, summed over sessions.
  Duration get workedTotal => spans.values
      .expand((list) => list)
      .where((s) => s.state == TimelineState.working)
      .fold(Duration.zero, (sum, s) => sum + s.duration);
}

/// [model] of [sessions] from [from] to [to], bucketed for the heartbeat.
OverviewActivityModel overviewActivityOf(
  TimelineModel model, {
  required DateTime from,
  required DateTime to,
}) {
  final spans = <String, List<TimelineSpan>>{
    for (final project in model.projects)
      for (final session in project.sessions)
        if (!session.startOnly) session.id: session.spans,
  };
  final step = to.difference(from) ~/ kOverviewBuckets;
  List<int> count(TimelineState state) => [
    for (var i = 0; i < kOverviewBuckets; i++)
      () {
        final at = from.add(step * i + step ~/ 2);
        return spans.values
            .where(
              (list) => list.any(
                (s) =>
                    s.state == state && !s.from.isAfter(at) && s.to.isAfter(at),
              ),
            )
            .length;
      }(),
  ];
  return OverviewActivityModel(
    from: from,
    to: to,
    spans: spans,
    working: count(TimelineState.working),
    waiting: count(TimelineState.waiting),
  );
}

/// The log query, fixed to the hour so a rebuild does not read it again.
TimelineQuery _queryAt(DateTime now) {
  final hour = DateTime.utc(now.year, now.month, now.day, now.hour);
  return TimelineQuery(
    from: hour.subtract(_kCarriedIn),
    to: hour.add(const Duration(days: 1)),
  );
}

/// **The last two hours, from the activity log**: what each strip and the
/// heartbeat draw. Unrecorded while the log is out of reach.
final overviewActivityProvider = Provider.autoDispose<OverviewActivityModel>((
  ref,
) {
  final now = ref.read(clockProvider).nowUtc();
  final entries = ref.watch(timelineEntriesProvider(_queryAt(now)));
  final list = entries.asData?.value;
  if (list == null) return OverviewActivityModel.unrecorded;
  final from = now.subtract(kOverviewWindow);
  return overviewActivityOf(
    buildTimeline(list, from: from, to: now, now: now),
    from: from,
    to: now,
  );
});
