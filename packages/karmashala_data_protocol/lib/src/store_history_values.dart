/// What the server keeps of each app over time: one row a day of its
/// numbers, and each release's steps through review as reads found them.
/// For the Stores tab's charts and release timelines. Never a credential.
library;

import 'package:store_console/store_console.dart';

/// One app's numbers on one day. A part the stores did not say that day is
/// null — unknown, never zero.
final class StoreDay {
  const StoreDay({
    required this.day,
    this.rating,
    this.ratingCount,
    this.reviews,
    this.crashRate,
    this.anrRate,
    this.installs,
  });

  /// Midnight UTC.
  final DateTime day;

  /// The average rating, 0..5.
  final double? rating;
  final int? ratingCount;

  /// Reviews written that day, among those the store's pages hold.
  final int? reviews;

  /// A fraction of daily users, 0..1, over the store's own window.
  final double? crashRate;
  final double? anrRate;

  /// First-time installs or downloads counted for that day. The stores
  /// report these days late, so the newest days are usually unknown.
  final int? installs;

  bool get empty =>
      rating == null &&
      ratingCount == null &&
      reviews == null &&
      crashRate == null &&
      anrRate == null &&
      installs == null;

  /// This day with every part [newer] knows replacing its own.
  StoreDay mergedWith(StoreDay newer) => StoreDay(
    day: day,
    rating: newer.rating ?? rating,
    ratingCount: newer.ratingCount ?? ratingCount,
    reviews: newer.reviews ?? reviews,
    crashRate: newer.crashRate ?? crashRate,
    anrRate: newer.anrRate ?? anrRate,
    installs: newer.installs ?? installs,
  );

  /// One compact row: `[day, rating, ratingCount, reviews, crashRate,
  /// anrRate, installs]`, the day as `2026-10-09`.
  List<Object?> toJson() => [
    storeDayKey(day),
    rating,
    ratingCount,
    reviews,
    crashRate,
    anrRate,
    installs,
  ];

  factory StoreDay.fromJson(Object? json) {
    final row = json! as List;
    Object? at(int i) => i < row.length ? row[i] : null;
    return StoreDay(
      day: DateTime.parse('${row[0]! as String}T00:00:00Z'),
      rating: (at(1) as num?)?.toDouble(),
      ratingCount: (at(2) as num?)?.toInt(),
      reviews: (at(3) as num?)?.toInt(),
      crashRate: (at(4) as num?)?.toDouble(),
      anrRate: (at(5) as num?)?.toDouble(),
      installs: (at(6) as num?)?.toInt(),
    );
  }
}

/// Midnight UTC of [at]'s UTC day.
DateTime storeDayOf(DateTime at) {
  final utc = at.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day);
}

/// `2026-10-09`: [day]'s UTC calendar day.
String storeDayKey(DateTime day) {
  final utc = day.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final date = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$date';
}

/// One release reaching a state, as a read found it.
final class StoreReleaseStep {
  const StoreReleaseStep({
    required this.track,
    required this.version,
    required this.state,
    required this.rawState,
    required this.words,
    required this.at,
    this.build,
    this.rollout,
    this.firstRead = false,
  });

  final String track;
  final String version;
  final String? build;
  final ReleaseState state;

  /// The store's own word: `WAITING_FOR_REVIEW`, `METADATA_REJECTED`.
  final String rawState;

  /// How the state is said: `Ready for sale`, `Rolling out 20%`, `Metadata
  /// rejected` — which is also all a store says of why it rejected.
  final String words;

  /// 0..1 while a staged rollout is under way.
  final double? rollout;

  /// When it was found in this state. With [firstRead], when the release was
  /// first read already in it — the store's own date where it gave one, else
  /// the read's — so it may have got there earlier.
  final DateTime at;
  final bool firstRead;

  Map<String, Object?> toJson() => {
    'track': track,
    'version': version,
    'build': ?build,
    'state': state.name,
    'rawState': rawState,
    'words': words,
    'rollout': ?rollout,
    'at': at.toUtc().toIso8601String(),
    if (firstRead) 'firstRead': true,
  };

  factory StoreReleaseStep.fromJson(Map<String, Object?> json) =>
      StoreReleaseStep(
        track: json['track']! as String,
        version: json['version']! as String,
        build: json['build'] as String?,
        state: ReleaseState.parse(json['state']! as String),
        rawState: json['rawState'] as String? ?? '',
        words: json['words'] as String? ?? '',
        rollout: (json['rollout'] as num?)?.toDouble(),
        at: DateTime.parse(json['at']! as String),
        firstRead: json['firstRead'] == true,
      );
}

/// What the server kept of one app.
final class StoreAppHistory {
  const StoreAppHistory({
    required this.app,
    this.days = const [],
    this.steps = const [],
  });

  final StoreApp app;

  /// Oldest first, one a day at most; a day never read is absent.
  final List<StoreDay> days;

  /// Oldest first.
  final List<StoreReleaseStep> steps;

  Map<String, Object?> toJson() => {
    'app': app.toJson(),
    'days': [for (final day in days) day.toJson()],
    'steps': [for (final step in steps) step.toJson()],
  };

  factory StoreAppHistory.fromJson(Map<String, Object?> json) =>
      StoreAppHistory(
        app: StoreApp.fromJson((json['app']! as Map).cast<String, Object?>()),
        days: [
          for (final day in (json['days'] as List?) ?? const [])
            StoreDay.fromJson(day),
        ],
        steps: [
          for (final step in (json['steps'] as List?) ?? const [])
            StoreReleaseStep.fromJson((step as Map).cast<String, Object?>()),
        ],
      );
}

/// The history asked for, one per app the server keeps any of.
final class StoreHistoryView {
  const StoreHistoryView({this.apps = const [], this.keptDays = 0});

  final List<StoreAppHistory> apps;

  /// How many days the server keeps.
  final int keptDays;

  /// [appKey]'s history, or null.
  StoreAppHistory? of(String appKey) {
    for (final held in apps) {
      if (held.app.key == appKey) return held;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'apps': [for (final held in apps) held.toJson()],
    'keptDays': keptDays,
  };

  factory StoreHistoryView.fromJson(Map<String, Object?> json) =>
      StoreHistoryView(
        apps: [
          for (final held in (json['apps'] as List?) ?? const [])
            StoreAppHistory.fromJson((held as Map).cast<String, Object?>()),
        ],
        keptDays: (json['keptDays'] as num?)?.toInt() ?? 0,
      );
}
