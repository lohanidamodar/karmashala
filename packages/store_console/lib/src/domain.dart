/// The values every store is translated into.
library;

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
  const RatingSummary({required this.average, this.count});

  /// 0..5.
  final double average;

  /// How many ratings it is the average of, when the store says.
  final int? count;

  Map<String, Object?> toJson() => {'average': average, 'count': count};

  factory RatingSummary.fromJson(Map<String, Object?> json) => RatingSummary(
    average: (json['average']! as num).toDouble(),
    count: (json['count'] as num?)?.toInt(),
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

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
