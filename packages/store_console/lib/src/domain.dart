/// The values every store is translated into.
library;

import 'dart:typed_data';

enum StoreKind {
  appStore('App Store'),
  googlePlay('Google Play');

  const StoreKind(this.label);
  final String label;

  static StoreKind parse(String name) =>
      values.firstWhere((kind) => kind.name == name);
}

/// One app on one store.
class StoreApp {
  const StoreApp({
    required this.store,
    required this.id,
    required this.bundleId,
    required this.name,
  });

  final StoreKind store;

  /// What the store's own API addresses the app by: the numeric App Store
  /// id, or the Play package name.
  final String id;

  /// The bundle identifier or package name; the same on both stores for most
  /// apps, which is what pairs the two listings.
  final String bundleId;

  final String name;

  String get key => '${store.name}:$id';

  Map<String, Object?> toJson() => {
    'store': store.name,
    'id': id,
    'bundleId': bundleId,
    'name': name,
  };

  factory StoreApp.fromJson(Map<String, Object?> json) => StoreApp(
    store: StoreKind.parse(json['store']! as String),
    id: json['id']! as String,
    bundleId: json['bundleId']! as String,
    name: json['name']! as String,
  );

  @override
  bool operator ==(Object other) =>
      other is StoreApp && other.store == store && other.id == id;

  @override
  int get hashCode => Object.hash(store, id);
}

/// Where a release stands, in the words both stores can be reduced to.
/// [StoreRelease.rawState] keeps the store's own word.
enum ReleaseState {
  live('Live'),
  rollingOut('Rolling out'),
  pendingRelease('Approved, not released'),
  inReview('In review'),
  waitingForReview('Waiting for review'),
  processing('Processing'),
  draft('Draft'),
  rejected('Rejected'),
  halted('Halted'),
  removed('Removed'),
  superseded('Replaced'),
  expired('Expired'),
  testing('In testing'),
  unknown('Unknown');

  const ReleaseState(this.label);
  final String label;

  /// Whether somebody has to do something before this release moves.
  bool get needsAttention => this == rejected || this == halted;

  /// Whether it is on its way and not yet settled.
  bool get inFlight => const {
    rollingOut,
    pendingRelease,
    inReview,
    waitingForReview,
    processing,
  }.contains(this);

  static ReleaseState parse(String name) =>
      values.firstWhere((state) => state.name == name, orElse: () => unknown);
}

/// One version on one track.
class StoreRelease {
  const StoreRelease({
    required this.track,
    required this.version,
    required this.state,
    required this.rawState,
    this.build,
    this.rolloutFraction,
    this.date,
  });

  /// `App Store`, `TestFlight`, or the Play track: `production`, `beta`,
  /// `alpha`, `internal`, or a custom one.
  final String track;

  /// The version a user sees. Empty when the store names only a build.
  final String version;

  final String? build;
  final ReleaseState state;
  final String rawState;

  /// 0..1 while a staged or phased rollout is under way; null otherwise.
  final double? rolloutFraction;

  /// When the store says it was created or released, when it says.
  final DateTime? date;

  /// Whether this came after [other] on the same track, by date when both
  /// have one, else by build number; false when neither says.
  bool isNewerThan(StoreRelease other) {
    final (mine, theirs) = (date, other.date);
    if (mine != null && theirs != null) return mine.isAfter(theirs);
    final (a, b) = (int.tryParse(build ?? ''), int.tryParse(other.build ?? ''));
    return a != null && b != null && a > b;
  }

  Map<String, Object?> toJson() => {
    'track': track,
    'version': version,
    'state': state.name,
    'rawState': rawState,
    'build': build,
    'rolloutFraction': rolloutFraction,
    'date': date?.toUtc().toIso8601String(),
  };

  factory StoreRelease.fromJson(Map<String, Object?> json) => StoreRelease(
    track: json['track']! as String,
    version: json['version']! as String,
    state: ReleaseState.parse(json['state']! as String),
    rawState: json['rawState']! as String,
    build: json['build'] as String?,
    rolloutFraction: (json['rolloutFraction'] as num?)?.toDouble(),
    date: _date(json['date']),
  );
}

class StoreReview {
  const StoreReview({
    required this.id,
    required this.rating,
    required this.body,
    required this.createdAt,
    this.title,
    this.author,
    this.locale,
    this.appVersion,
    this.reply,
    this.repliedAt,
  });

  final String id;

  /// 1..5.
  final int rating;
  final String body;
  final DateTime createdAt;
  final String? title;
  final String? author;

  /// A territory (`USA`) on the App Store, a language (`en_US`) on Play.
  final String? locale;
  final String? appVersion;
  final String? reply;
  final DateTime? repliedAt;

  bool get answered => reply != null;

  Map<String, Object?> toJson() => {
    'id': id,
    'rating': rating,
    'body': body,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'title': title,
    'author': author,
    'locale': locale,
    'appVersion': appVersion,
    'reply': reply,
    'repliedAt': repliedAt?.toUtc().toIso8601String(),
  };

  factory StoreReview.fromJson(Map<String, Object?> json) => StoreReview(
    id: json['id']! as String,
    rating: (json['rating']! as num).toInt(),
    body: json['body']! as String,
    createdAt: DateTime.parse(json['createdAt']! as String),
    title: json['title'] as String?,
    author: json['author'] as String?,
    locale: json['locale'] as String?,
    appVersion: json['appVersion'] as String?,
    reply: json['reply'] as String?,
    repliedAt: _date(json['repliedAt']),
  );
}

class RatingSummary {
  const RatingSummary({
    required this.average,
    this.count,
    this.history = const [],
  });

  /// 0..5.
  final double average;

  /// How many ratings it is the average of, when the store says.
  final int? count;

  /// The average as read on earlier days, oldest first, one point a day.
  /// Neither store gives this; whoever keeps the readings carries it over
  /// with [carriedFrom].
  final List<RatingPoint> history;

  /// How many days of [history] are kept.
  static const int historyDays = 35;

  /// The window [trend] compares over.
  static const Duration trendWindow = Duration(days: 7);

  /// The change since about [trendWindow] ago: the newest point at least that
  /// old, else the oldest point from an earlier day. Null with no such point.
  ({double change, DateTime since})? get trend {
    if (history.isEmpty) return null;
    final today = history.last.day;
    RatingPoint? base;
    for (final point in history) {
      if (today.difference(point.day) >= trendWindow) base = point;
    }
    base ??= history.first.day.isBefore(today) ? history.first : null;
    if (base == null) return null;
    return (change: average - base.average, since: base.day);
  }

  /// This reading at [at], with [previous]'s history carried over and today's
  /// point set to this average.
  RatingSummary carriedFrom(RatingSummary? previous, DateTime at) {
    final utc = at.toUtc();
    final day = DateTime.utc(utc.year, utc.month, utc.day);
    final oldest = day.subtract(const Duration(days: historyDays));
    return RatingSummary(
      average: average,
      count: count,
      history: [
        for (final point in previous?.history ?? const <RatingPoint>[])
          if (point.day.isAfter(oldest) && point.day.isBefore(day)) point,
        RatingPoint(day, average),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'average': average,
    'count': count,
    if (history.isNotEmpty)
      'history': [for (final point in history) point.toJson()],
  };

  factory RatingSummary.fromJson(Map<String, Object?> json) => RatingSummary(
    average: (json['average']! as num).toDouble(),
    count: (json['count'] as num?)?.toInt(),
    history: [
      for (final point in (json['history'] as List?) ?? const [])
        RatingPoint.fromJson((point as Map).cast<String, Object?>()),
    ],
  );
}

/// The average rating as read on one day.
class RatingPoint {
  const RatingPoint(this.day, this.average);

  /// Midnight UTC.
  final DateTime day;
  final double average;

  Map<String, Object?> toJson() => {
    'day': day.toUtc().toIso8601String(),
    'average': average,
  };

  factory RatingPoint.fromJson(Map<String, Object?> json) => RatingPoint(
    DateTime.parse(json['day']! as String),
    (json['average']! as num).toDouble(),
  );
}

/// Stability over a window. A rate is a fraction of daily users, 0..1, and
/// null when the store had too little data to publish one.
class VitalsSummary {
  const VitalsSummary({
    required this.from,
    required this.to,
    this.crashRate,
    this.anrRate,
  });

  final DateTime from;
  final DateTime to;
  final double? crashRate;
  final double? anrRate;

  Map<String, Object?> toJson() => {
    'from': from.toUtc().toIso8601String(),
    'to': to.toUtc().toIso8601String(),
    'crashRate': crashRate,
    'anrRate': anrRate,
  };

  factory VitalsSummary.fromJson(Map<String, Object?> json) => VitalsSummary(
    from: DateTime.parse(json['from']! as String),
    to: DateTime.parse(json['to']! as String),
    crashRate: (json['crashRate'] as num?)?.toDouble(),
    anrRate: (json['anrRate'] as num?)?.toDouble(),
  );
}

class DailyCount {
  const DailyCount(this.day, this.count);

  /// Midnight UTC of the day counted.
  final DateTime day;
  final int count;
}

/// First-time downloads or installs per day, oldest first. A day the store
/// has not reported yet is absent, not zero.
class DownloadSeries {
  const DownloadSeries({required this.unit, required this.days});

  /// What is being counted, in the store's word: `Units`, `Installs`.
  final String unit;
  final List<DailyCount> days;

  int get total => days.fold(0, (sum, day) => sum + day.count);

  Map<String, Object?> toJson() => {
    'unit': unit,
    'days': [
      for (final day in days)
        {'day': day.day.toUtc().toIso8601String(), 'count': day.count},
    ],
  };

  factory DownloadSeries.fromJson(Map<String, Object?> json) => DownloadSeries(
    unit: json['unit']! as String,
    days: [
      for (final day in (json['days']! as List).cast<Map<String, Object?>>())
        DailyCount(
          DateTime.parse(day['day']! as String),
          (day['count']! as num).toInt(),
        ),
    ],
  );
}

/// An app's icon as its public store page shows it: a small square image,
/// fetched, not kept — whoever reads it decides where it lives.
class StoreIconImage {
  const StoreIconImage({
    required this.source,
    required this.bytes,
    required this.contentType,
  });

  /// Where the image was fetched from: a public URL, safe to show.
  final Uri source;
  final Uint8List bytes;

  /// `image/png`, `image/jpeg` or `image/webp`.
  final String contentType;

  /// The file extension [contentType] is written with, dot included.
  String get extension => switch (contentType) {
    'image/jpeg' || 'image/jpg' => '.jpg',
    'image/webp' => '.webp',
    _ => '.png',
  };
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// What kind of failure an [StoreErrorIssue] groups.
enum StoreErrorKind {
  crash('Crash'),
  anr('ANR');

  const StoreErrorKind(this.label);
  final String label;

  static StoreErrorKind? parse(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// One cluster of crashes or ANRs the store grouped together, with a sample
/// report's stack trace when one could be read.
class StoreErrorIssue {
  const StoreErrorIssue({
    required this.id,
    required this.kind,
    required this.cause,
    required this.location,
    this.reportCount,
    this.distinctUsers,
    this.lastSeen,
    this.firstVersionCode,
    this.lastVersionCode,
    this.consoleUrl,
    this.sampleTrace,
    this.sampleAt,
    this.sampleVersionCode,
  });

  final String id;
  final StoreErrorKind kind;

  /// The exception or signal for a crash; the reason for an ANR.
  final String cause;

  /// The likely method for a crash; the unresponsive component for an ANR.
  final String location;

  /// Over the window the store was asked about.
  final int? reportCount;
  final int? distinctUsers;
  final DateTime? lastSeen;
  final String? firstVersionCode;
  final String? lastVersionCode;

  /// The issue in the store's own console.
  final String? consoleUrl;

  /// One report's full text, cut to [sampleTraceLimit] characters.
  final String? sampleTrace;
  final DateTime? sampleAt;
  final String? sampleVersionCode;

  static const int sampleTraceLimit = 12000;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'cause': cause,
    'location': location,
    'reportCount': reportCount,
    'distinctUsers': distinctUsers,
    'lastSeen': lastSeen?.toUtc().toIso8601String(),
    'firstVersionCode': firstVersionCode,
    'lastVersionCode': lastVersionCode,
    'consoleUrl': consoleUrl,
    'sampleTrace': sampleTrace,
    'sampleAt': sampleAt?.toUtc().toIso8601String(),
    'sampleVersionCode': sampleVersionCode,
  };

  factory StoreErrorIssue.fromJson(
    Map<String, Object?> json,
  ) => StoreErrorIssue(
    id: json['id']! as String,
    kind: StoreErrorKind.parse(json['kind'] as String?) ?? StoreErrorKind.crash,
    cause: json['cause'] as String? ?? '',
    location: json['location'] as String? ?? '',
    reportCount: (json['reportCount'] as num?)?.toInt(),
    distinctUsers: (json['distinctUsers'] as num?)?.toInt(),
    lastSeen: _date(json['lastSeen']),
    firstVersionCode: json['firstVersionCode'] as String?,
    lastVersionCode: json['lastVersionCode'] as String?,
    consoleUrl: json['consoleUrl'] as String?,
    sampleTrace: json['sampleTrace'] as String?,
    sampleAt: _date(json['sampleAt']),
    sampleVersionCode: json['sampleVersionCode'] as String?,
  );
}
