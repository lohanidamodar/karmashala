import 'package:store_console/store_console.dart';

import 'store_attention.dart';
import 'store_groups.dart';

/// How many days the summary's rating sparkline covers.
const int kSummaryTrendDays = 30;

/// One app on one store as a row of the summary across every app.
class StoreSummaryRow {
  StoreSummaryRow(this.group, this.entry);

  /// The app as its owner thinks of it: what a click opens.
  final StoreAppGroup group;

  /// This row's store.
  final StoreEntry entry;

  StoreApp get app => entry.app;
  StoreAppSnapshot? get snapshot => entry.snapshot;

  /// `iOS`, `macOS`, `Android`.
  String get platform =>
      snapshot?.platform ??
      (app.store == StoreKind.googlePlay ? 'Android' : 'iOS');

  /// What users have now; null when nothing is out or it was not read.
  StoreRelease? get live => snapshot?.live;

  /// The release that most wants a look: stuck or on its way.
  StoreRelease? get pending => entry.pending;

  RatingSummary? get rating => snapshot?.rating.valueOrNull;

  /// The average on each day read over the last [kSummaryTrendDays], oldest
  /// first. A day never read is left out, never drawn as a zero.
  List<double> get ratingTrend {
    final history = rating?.history ?? const <RatingPoint>[];
    if (history.isEmpty) return const [];
    final newest = history.last.day;
    final from = newest.subtract(const Duration(days: kSummaryTrendDays - 1));
    return [
      for (final point in history)
        if (!point.day.isBefore(from)) point.average,
    ];
  }

  /// Reviews written in the week before they were read; null when the
  /// reviews were not read.
  int? get newReviewCount {
    final reading = snapshot?.reviews;
    if (reading is! ReadingValue<List<StoreReview>>) return null;
    return newReviews(reading.value, reading.checkedAt).length;
  }

  /// Of [newReviewCount], those nobody has answered.
  int? get unanswered {
    final reading = snapshot?.reviews;
    if (reading is! ReadingValue<List<StoreReview>>) return null;
    return newReviews(
      reading.value,
      reading.checkedAt,
    ).where((review) => !review.answered).length;
  }

  /// The stability the store reports; null where it reports none — the App
  /// Store has no crash rate — or it was not read.
  VitalsSummary? get vitals => snapshot?.vitals.valueOrNull;

  /// Changes found since somebody last opened the app.
  bool get changedUnseen {
    final changes = entry.changes;
    return changes != null && !changes.seen;
  }

  /// The loudest thing this store says of the app; null when nothing.
  StoreTone? get tone =>
      entry.signals.isEmpty ? null : entry.signals.first.tone;

  bool get needsAttention => tone == StoreTone.attention;

  bool get inFlight => entry.signals.any(
    (signal) => signal is ReleaseSignal && signal.release.state.inFlight,
  );

  /// Where this row sorts: what needs the owner first, then what is moving,
  /// then what changed unseen, then unanswered reviews, then the rest.
  int get rank {
    if (needsAttention) return 0;
    if (inFlight) return 1;
    if (changedUnseen) return 2;
    if ((unanswered ?? 0) > 0) return 3;
    return 4;
  }
}

/// A row per app per store, what needs attention first ([StoreSummaryRow.rank]),
/// then by name, App Store before Google Play.
List<StoreSummaryRow> storeSummaryRows(List<StoreAppGroup> groups) {
  final rows = [
    for (final group in groups)
      for (final entry in group.entries) StoreSummaryRow(group, entry),
  ];
  return rows..sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    final byName = a.app.name.toLowerCase().compareTo(b.app.name.toLowerCase());
    if (byName != 0) return byName;
    final byStore = a.app.store.index.compareTo(b.app.store.index);
    return byStore != 0 ? byStore : a.app.key.compareTo(b.app.key);
  });
}

/// A rating trend's scale: its own range with a little room, at least half a
/// star tall, so a month's movement shows instead of a flat line on 1..5.
({double min, double max}) ratingTrendScale(List<double> values) {
  if (values.isEmpty) return (min: 1, max: 5);
  var low = values.reduce((a, b) => a < b ? a : b);
  var high = values.reduce((a, b) => a > b ? a : b);
  final middle = (low + high) / 2;
  if (high - low < 0.5) {
    low = middle - 0.25;
    high = middle + 0.25;
  }
  return (min: (low - 0.05).clamp(0, 5), max: (high + 0.05).clamp(0, 5));
}

/// The sections the Stores list is in, table and cards alike, in order.
enum StoreSection {
  attention('Needs attention'),
  inProgress('In progress'),
  changed('Changed since you last looked'),
  rest('Everything else');

  const StoreSection(this.title);
  final String title;
}

/// The one section [group] is listed in: the first that holds of it.
StoreSection storeSectionOf(StoreAppGroup group) {
  if (group.needsAttention) return StoreSection.attention;
  if (group.inFlight) return StoreSection.inProgress;
  if (group.changedUnseen) return StoreSection.changed;
  return StoreSection.rest;
}

/// [groups] in their sections, each keeping [groups]' order; a section with
/// no app is left out.
List<(StoreSection, List<StoreAppGroup>)> storeSections(
  Iterable<StoreAppGroup> groups,
) {
  final by = <StoreSection, List<StoreAppGroup>>{};
  for (final group in groups) {
    by.putIfAbsent(storeSectionOf(group), () => []).add(group);
  }
  return [
    for (final section in StoreSection.values)
      if (by[section] case final members?) (section, members),
  ];
}

/// [group]'s rows, one per store it is on, App Store first.
List<StoreSummaryRow> storeSummaryRowsOf(StoreAppGroup group) => [
  for (final entry in group.entries) StoreSummaryRow(group, entry),
];
