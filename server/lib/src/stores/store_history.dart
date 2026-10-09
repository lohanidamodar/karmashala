import 'dart:math' as math;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import 'store_digest.dart';

/// How many days of each app's numbers are kept.
const int kStoreHistoryDays = 365;

/// How many release steps are kept per app, oldest dropped first.
const int kStoreHistoryStepLimit = 400;

/// Releases in these states are finished: a first read of one is not a step
/// worth keeping.
const _finishedStates = {
  ReleaseState.expired,
  ReleaseState.superseded,
  ReleaseState.removed,
};

/// What is kept of each app over time, by [StoreApp.key]: one row a day of
/// its numbers ([StoreDay]) and each release's steps ([StoreReleaseStep]).
/// Only what a read said is kept; a part it did not say stays unknown.
class StoreHistoryBook {
  StoreHistoryBook();

  final _apps = <String, StoreApp>{};

  /// By app key, then by [storeDayKey].
  final _days = <String, Map<String, StoreDay>>{};

  /// By app key, oldest first.
  final _steps = <String, List<StoreReleaseStep>>{};

  bool get isEmpty => _apps.isEmpty;

  /// Keeps what [snapshot], read at [now], says: today's rating and
  /// stability, the reviews written on each day its reviews cover, the
  /// installs on each day its downloads report, and any release whose state
  /// moved since the last read.
  void record(StoreAppSnapshot snapshot, DateTime now) {
    final key = snapshot.app.key;
    _apps[key] = snapshot.app;
    final days = _days.putIfAbsent(key, () => {});
    final today = storeDayOf(now);

    void merge(StoreDay fresh) {
      if (fresh.empty) return;
      final dayKey = storeDayKey(fresh.day);
      final held = days[dayKey];
      days[dayKey] = held == null ? fresh : held.mergedWith(fresh);
    }

    final rating = snapshot.rating.valueOrNull;
    final vitals = snapshot.vitals.valueOrNull;
    merge(
      StoreDay(
        day: today,
        rating: rating?.average,
        ratingCount: rating?.count,
        crashRate: vitals?.crashRate,
        anrRate: vitals?.anrRate,
      ),
    );

    if (snapshot.reviews case ReadingValue(value: final reviews)) {
      final counts = <String, int>{};
      var oldest = today;
      for (final review in reviews) {
        final day = storeDayOf(review.createdAt);
        if (day.isAfter(today)) continue;
        if (day.isBefore(oldest)) oldest = day;
        counts.update(storeDayKey(day), (n) => n + 1, ifAbsent: () => 1);
      }
      // Every day from the oldest review read to today is covered: a day
      // with none written is a zero. A page that cut its oldest day short
      // never lowers what an earlier read counted.
      for (
        var day = oldest;
        !day.isAfter(today);
        day = DateTime.utc(day.year, day.month, day.day + 1)
      ) {
        final dayKey = storeDayKey(day);
        final counted = counts[dayKey] ?? 0;
        final held = days[dayKey]?.reviews;
        merge(StoreDay(day: day, reviews: math.max(counted, held ?? 0)));
      }
    }

    if (snapshot.downloads case ReadingValue(value: final series)) {
      for (final reported in series.days) {
        final day = storeDayOf(reported.day);
        if (day.isAfter(today)) continue;
        merge(StoreDay(day: day, installs: reported.count));
      }
    }

    if (snapshot.releases case ReadingValue(value: final releases)) {
      _recordSteps(snapshot.app.store, key, releases, now);
    }
    _trim(key, now);
  }

  void _recordSteps(
    StoreKind store,
    String appKey,
    List<StoreRelease> releases,
    DateTime now,
  ) {
    final steps = _steps.putIfAbsent(appKey, () => []);
    final last = <String, StoreReleaseStep>{
      for (final step in steps) _stepKey(store, step): step,
    };
    for (final release in releases) {
      final key = releaseKey(store, release);
      final digest = ReleaseDigest.of(release);
      final held = last[key];
      if (held == null) {
        if (_finishedStates.contains(release.state)) continue;
        steps.add(_step(store, release, digest, at: now, firstRead: true));
        continue;
      }
      if (held.state == release.state &&
          held.rawState == release.rawState &&
          held.rollout == release.rolloutFraction) {
        continue;
      }
      steps.add(_step(store, release, digest, at: now));
    }
    steps.sort((a, b) => a.at.compareTo(b.at));
  }

  static StoreReleaseStep _step(
    StoreKind store,
    StoreRelease release,
    ReleaseDigest digest, {
    required DateTime at,
    bool firstRead = false,
  }) => StoreReleaseStep(
    track: release.track,
    version: release.version,
    build: release.build,
    state: release.state,
    rawState: release.rawState,
    words: stateWords(store, digest),
    rollout: release.rolloutFraction,
    at: at.toUtc(),
    firstRead: firstRead,
  );

  static String _stepKey(StoreKind store, StoreReleaseStep step) => releaseKey(
    store,
    StoreRelease(
      track: step.track,
      version: step.version,
      build: step.build,
      state: step.state,
      rawState: step.rawState,
    ),
  );

  /// Drops days past [kStoreHistoryDays] and steps past it too, keeping each
  /// release's newest step — it is what the next read is compared with —
  /// then the oldest past [kStoreHistoryStepLimit].
  void _trim(String appKey, DateTime now) {
    final cutoff = storeDayOf(
      now,
    ).subtract(const Duration(days: kStoreHistoryDays));
    _days[appKey]?.removeWhere((_, day) => day.day.isBefore(cutoff));
    final steps = _steps[appKey];
    final app = _apps[appKey];
    if (steps == null || app == null) return;
    final newest = <String, StoreReleaseStep>{
      for (final step in steps) _stepKey(app.store, step): step,
    };
    final kept = {...newest.values};
    steps.removeWhere(
      (step) => step.at.isBefore(cutoff) && !kept.contains(step),
    );
    if (steps.length > kStoreHistoryStepLimit) {
      steps.removeRange(0, steps.length - kStoreHistoryStepLimit);
    }
  }

  /// Forgets every app [gone] names.
  void forget(bool Function(StoreApp app) gone) {
    final keys = [
      for (final MapEntry(:key, :value) in _apps.entries)
        if (gone(value)) key,
    ];
    for (final key in keys) {
      _apps.remove(key);
      _days.remove(key);
      _steps.remove(key);
    }
  }

  /// The last [days] days of the apps [include] lets through, at [now];
  /// every release step kept, so a timeline begins where its release did.
  StoreHistoryView view({
    required int days,
    required DateTime now,
    bool Function(StoreApp app)? include,
  }) {
    final from = storeDayOf(now).subtract(Duration(days: days - 1));
    return StoreHistoryView(
      keptDays: kStoreHistoryDays,
      apps: [
        for (final MapEntry(:key, value: app) in _apps.entries)
          if (include == null || include(app))
            StoreAppHistory(
              app: app,
              days: [
                for (final day
                    in (_days[key]?.values.toList() ?? <StoreDay>[])
                      ..sort((a, b) => a.day.compareTo(b.day)))
                  if (!day.day.isBefore(from)) day,
              ],
              steps: List.unmodifiable(_steps[key] ?? const []),
            ),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, value: app) in _apps.entries)
      key: {
        'app': app.toJson(),
        'days': [
          for (final day
              in (_days[key]?.values.toList() ?? <StoreDay>[])
                ..sort((a, b) => a.day.compareTo(b.day)))
            day.toJson(),
        ],
        'steps': [for (final step in _steps[key] ?? const []) step.toJson()],
      },
  };

  /// What [toJson] wrote; an app that does not read is left out, not fatal.
  factory StoreHistoryBook.fromJson(Map<String, Object?> json) {
    final book = StoreHistoryBook();
    for (final MapEntry(:key, :value) in json.entries) {
      try {
        final held = StoreAppHistory.fromJson(
          (value! as Map).cast<String, Object?>(),
        );
        book._apps[key] = held.app;
        book._days[key] = {
          for (final day in held.days) storeDayKey(day.day): day,
        };
        book._steps[key] = [...held.steps];
      } on Object {
        continue;
      }
    }
    return book;
  }
}
