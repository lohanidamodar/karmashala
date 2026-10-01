import 'package:store_console/store_console.dart';

/// How loudly a signal asks for the owner.
enum StoreTone {
  /// Somebody has to act: a rejection, a halt, a falling rating, a
  /// complaint, a reading that failed.
  attention,

  /// On its way: in review, processing, approved, rolling out.
  working,

  /// Worth a look, nothing to do: new reviews that are not complaints.
  info,
}

/// One reading of an app, named for what failed to be read.
enum StoreArea {
  releases('Releases'),
  reviews('Reviews'),
  rating('Rating'),
  vitals('Crash and ANR rates'),
  downloads('Downloads');

  const StoreArea(this.label);
  final String label;

  Reading<Object?> of(StoreAppSnapshot snapshot) => switch (this) {
    releases => snapshot.releases,
    reviews => snapshot.reviews,
    rating => snapshot.rating,
    vitals => snapshot.vitals,
    downloads => snapshot.downloads,
  };
}

/// Something about one app on one store that the overview puts first.
sealed class StoreSignal {
  const StoreSignal(this.store);

  final StoreKind store;
  StoreTone get tone;
}

/// A release somebody is waiting on or has to act on.
final class ReleaseSignal extends StoreSignal {
  const ReleaseSignal(super.store, this.release);

  final StoreRelease release;

  @override
  StoreTone get tone =>
      release.state.needsAttention ? StoreTone.attention : StoreTone.working;
}

/// Reviews written in the week before they were read.
final class NewReviewsSignal extends StoreSignal {
  const NewReviewsSignal(
    super.store, {
    required this.count,
    required this.unansweredLow,
  });

  final int count;

  /// Of [count], those of one or two stars nobody has answered.
  final int unansweredLow;

  @override
  StoreTone get tone =>
      unansweredLow > 0 ? StoreTone.attention : StoreTone.info;
}

/// The rating fell by at least [kRatingDropWorthSaying] over about a week.
final class RatingDropSignal extends StoreSignal {
  const RatingDropSignal(
    super.store, {
    required this.change,
    required this.since,
  });

  final double change;
  final DateTime since;

  @override
  StoreTone get tone => StoreTone.attention;
}

/// A reading that failed for this app alone; one failing for every app of a
/// store is said once, above the overview, instead. Info, not attention: it
/// is the reading that is in trouble, not the app.
final class UnreadSignal extends StoreSignal {
  const UnreadSignal(super.store, this.area, this.message);

  final StoreArea area;
  final String message;

  @override
  StoreTone get tone => StoreTone.info;
}

/// How far a rating has to fall in a week to be called out.
const double kRatingDropWorthSaying = 0.1;

/// How recent a review is to count as new: Play's API returns no older one.
const Duration kNewReviewWindow = Duration(days: 7);

/// [reviews] written within [kNewReviewWindow] before [readAt].
List<StoreReview> newReviews(List<StoreReview> reviews, DateTime readAt) => [
  for (final review in reviews)
    if (readAt.difference(review.createdAt) <= kNewReviewWindow) review,
];

/// What one store's [snapshot] of an app has to say, loudest first.
/// [storeWide] holds the failures said once for the whole store, by area.
List<StoreSignal> storeSignals(
  StoreAppSnapshot snapshot, {
  Map<StoreArea, String> storeWide = const {},
}) {
  final store = snapshot.app.store;
  final signals = <StoreSignal>[
    for (final release in snapshot.pending) ReleaseSignal(store, release),
  ];
  if (snapshot.reviews case ReadingValue(:final value, :final checkedAt)) {
    final fresh = newReviews(value, checkedAt);
    if (fresh.isNotEmpty) {
      signals.add(
        NewReviewsSignal(
          store,
          count: fresh.length,
          unansweredLow: fresh
              .where((review) => review.rating <= 2 && !review.answered)
              .length,
        ),
      );
    }
  }
  if (snapshot.rating.valueOrNull?.trend case final trend?
      when trend.change <= -kRatingDropWorthSaying) {
    signals.add(
      RatingDropSignal(store, change: trend.change, since: trend.since),
    );
  }
  for (final area in StoreArea.values) {
    if (area.of(snapshot) case ReadingMissing<Object?>(
      :final message,
      :final expected,
    ) when !expected && storeWide[area] != message) {
      signals.add(UnreadSignal(store, area, message));
    }
  }
  return signals..sort((a, b) => a.tone.index.compareTo(b.tone.index));
}

/// A failure that every app read from one store shares: said once.
class StoreWideMissing {
  const StoreWideMissing({
    required this.store,
    required this.areas,
    required this.message,
    required this.kind,
  });

  final StoreKind store;

  /// Every area that failed with [message].
  final List<StoreArea> areas;
  final String message;
  final StoreFailure kind;

  bool get expected =>
      kind == StoreFailure.notConfigured || kind == StoreFailure.notSupported;
}

/// The failures every app of a store shares, by store — what the overview says
/// once instead of on every card. A store with one app read says nothing
/// here: its card says it. Store-wide "not supported" (the App Store has no
/// crash rate) goes unsaid; it is not news.
List<StoreWideMissing> storeWideMissing(Iterable<StoreAppSnapshot> snapshots) {
  final byStore = <StoreKind, List<StoreAppSnapshot>>{};
  for (final snapshot in snapshots) {
    byStore.putIfAbsent(snapshot.app.store, () => []).add(snapshot);
  }
  final found = <StoreWideMissing>[];
  for (final MapEntry(key: store, value: all) in byStore.entries) {
    if (all.length < 2) continue;
    final byMessage = <String, ({StoreFailure kind, List<StoreArea> areas})>{};
    for (final area in StoreArea.values) {
      final first = area.of(all.first);
      if (first is! ReadingMissing<Object?>) continue;
      if (first.kind == StoreFailure.notSupported) continue;
      final shared = all.every(
        (snapshot) => switch (area.of(snapshot)) {
          ReadingMissing(:final message) => message == first.message,
          ReadingValue() => false,
        },
      );
      if (!shared) continue;
      byMessage
          .putIfAbsent(
            first.message,
            () => (kind: first.kind, areas: <StoreArea>[]),
          )
          .areas
          .add(area);
    }
    for (final MapEntry(key: message, :value) in byMessage.entries) {
      found.add(
        StoreWideMissing(
          store: store,
          areas: value.areas,
          message: message,
          kind: value.kind,
        ),
      );
    }
  }
  // Faults before setup, App Store before Google Play.
  return found..sort((a, b) {
    final byFault = (a.expected ? 1 : 0).compareTo(b.expected ? 1 : 0);
    return byFault != 0 ? byFault : a.store.index.compareTo(b.store.index);
  });
}

/// [missing] by store and area, for [storeSignals].
Map<StoreKind, Map<StoreArea, String>> storeWideByArea(
  Iterable<StoreWideMissing> missing,
) {
  final byStore = <StoreKind, Map<StoreArea, String>>{};
  for (final failure in missing) {
    final areas = byStore.putIfAbsent(failure.store, () => {});
    for (final area in failure.areas) {
      areas[area] = failure.message;
    }
  }
  return byStore;
}
