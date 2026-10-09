import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:store_console/store_console.dart';

import '../../../core/data/data_providers.dart';
import 'stores_controller.dart';

/// The spans the detail's charts offer.
enum StoreChartRange {
  month(30, '30 days'),
  quarter(90, '90 days'),
  year(365, '365 days');

  const StoreChartRange(this.days, this.label);
  final int days;
  final String label;
}

/// What the server kept of the apps [appKeys] names — `StoreApp.key`s joined
/// by commas, as [storeHistoryKey] makes them — over the longest range. Asked
/// again whenever the stores are read again.
final storeHistoryProvider = FutureProvider.autoDispose
    .family<StoreHistoryView, String>((ref, appKeys) async {
      ref.watch(
        storesProvider.select((async) => async.value?.view.refreshedAt),
      );
      final client = ref.watch(dataClientProvider);
      final reply = await client.send(
        StoresHistoryGet(
          appKeys: appKeys.split(','),
          days: StoreChartRange.year.days,
        ),
      );
      return reply.value;
    });

/// [apps]' keys as [storeHistoryProvider] takes them.
String storeHistoryKey(Iterable<StoreApp> apps) =>
    (apps.map((app) => app.key).toList()..sort()).join(',');

/// The first day [range] shows, ending on [now]'s day: midnight UTC.
DateTime storeRangeStart(StoreChartRange range, DateTime now) =>
    storeDayOf(now).subtract(Duration(days: range.days - 1));

/// [days]' known values of [pick] from [from] on, oldest first. A day with
/// no value is left out, so a chart draws a gap there, never a zero.
List<({DateTime day, double value})> storeDaySeries(
  List<StoreDay> days,
  double? Function(StoreDay day) pick, {
  required DateTime from,
}) => [
  for (final day in days)
    if (!day.day.isBefore(from))
      if (pick(day) case final value?) (day: day.day, value: value),
];

/// Reviews written per week, Monday to Sunday, over the weeks from [from] to
/// [to]; a week with no day counted is null — unknown, not none.
List<({DateTime week, int? count})> storeWeeklyReviews(
  List<StoreDay> days, {
  required DateTime from,
  required DateTime to,
}) {
  DateTime weekOf(DateTime day) {
    final start = storeDayOf(day);
    return start.subtract(Duration(days: start.weekday - DateTime.monday));
  }

  final counts = <DateTime, int>{};
  for (final day in days) {
    final reviews = day.reviews;
    if (reviews == null || day.day.isBefore(from) || day.day.isAfter(to)) {
      continue;
    }
    counts.update(
      weekOf(day.day),
      (sum) => sum + reviews,
      ifAbsent: () => reviews,
    );
  }
  final weeks = <({DateTime week, int? count})>[];
  for (
    var week = weekOf(from);
    !week.isAfter(to);
    week = DateTime.utc(week.year, week.month, week.day + 7)
  ) {
    weeks.add((week: week, count: counts[week]));
  }
  return weeks;
}

/// When each public release went out — first live or rolling out, as a read
/// saw it happen — for the charts' time axis; newest last.
List<({DateTime at, String version})> storeReleaseDates(
  StoreKind store,
  List<StoreReleaseStep> steps,
) {
  final seen = <String>{};
  final dates = <({DateTime at, String version})>[];
  for (final step in [...steps]..sort((a, b) => a.at.compareTo(b.at))) {
    final public = switch (store) {
      StoreKind.appStore => step.track.startsWith('App Store'),
      StoreKind.googlePlay => step.track == 'production',
    };
    if (!public || step.firstRead) continue;
    if (step.state != ReleaseState.live &&
        step.state != ReleaseState.rollingOut) {
      continue;
    }
    if (!seen.add('${step.track}|${step.version}')) continue;
    dates.add((at: step.at, version: step.version));
  }
  return dates;
}
