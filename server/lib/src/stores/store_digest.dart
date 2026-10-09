import 'dart:math' as math;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

/// How many review ids an app's digest keeps, newest first.
const int kDigestReviewLimit = 300;

/// The rating has to move this far to be told.
const double kRatingMoveWorthTelling = 0.1;

/// A crash rate this high, at least doubled, is told; Play calls 1.09% bad.
const double kCrashRateWorthTelling = 0.01;

/// The same for the ANR rate; Play calls 0.47% bad.
const double kAnrRateWorthTelling = 0.005;

/// One release as a digest keeps it.
final class ReleaseDigest {
  const ReleaseDigest({
    required this.track,
    required this.version,
    required this.state,
    required this.rawState,
    this.build,
    this.rollout,
  });

  factory ReleaseDigest.of(StoreRelease release) => ReleaseDigest(
    track: release.track,
    version: release.version,
    build: release.build,
    state: release.state,
    rawState: release.rawState,
    rollout: release.rolloutFraction,
  );

  final String track;
  final String version;
  final String? build;
  final ReleaseState state;
  final String rawState;
  final double? rollout;

  Map<String, Object?> toJson() => {
    'track': track,
    'version': version,
    'build': ?build,
    'state': state.name,
    'rawState': rawState,
    'rollout': ?rollout,
  };

  factory ReleaseDigest.fromJson(Map<String, Object?> json) => ReleaseDigest(
    track: json['track']! as String,
    version: json['version']! as String,
    build: json['build'] as String?,
    state: ReleaseState.parse(json['state']! as String),
    rawState: json['rawState'] as String? ?? '',
    rollout: (json['rollout'] as num?)?.toDouble(),
  );
}

/// One review as a digest keeps it: enough to tell a new one and its stars.
typedef ReviewDigest = ({DateTime at, int rating});

/// What is remembered of one app between reads, to tell what changed. Each
/// part is null until it has once been read; a part a read missed keeps
/// what it held ([mergedWith]), so a failed reading is never a change.
final class StoreDigest {
  const StoreDigest({
    this.releases,
    this.reviews,
    this.rating,
    this.ratingCount,
    this.errors,
    this.crashRate,
    this.anrRate,
    this.vitalsRead = false,
  });

  /// [snapshot]'s readings that have a value.
  factory StoreDigest.of(StoreAppSnapshot snapshot) {
    final vitals = snapshot.vitals.valueOrNull;
    final rating = snapshot.rating.valueOrNull;
    return StoreDigest(
      releases: switch (snapshot.releases) {
        ReadingValue(:final value) => {
          for (final release in value)
            releaseKey(snapshot.app.store, release): ReleaseDigest.of(release),
        },
        ReadingMissing() => null,
      },
      reviews: switch (snapshot.reviews) {
        ReadingValue(:final value) => {
          for (final review in value)
            review.id: (at: review.createdAt, rating: review.rating),
        },
        ReadingMissing() => null,
      },
      rating: rating?.average,
      ratingCount: rating?.count,
      errors: switch (snapshot.errorIssues) {
        ReadingValue(:final value) => {
          for (final issue in value) issue.id: _issueLabel(issue),
        },
        _ => null,
      },
      crashRate: vitals?.crashRate,
      anrRate: vitals?.anrRate,
      vitalsRead: vitals != null,
    );
  }

  /// By [releaseKey].
  final Map<String, ReleaseDigest>? releases;

  /// By review id.
  final Map<String, ReviewDigest>? reviews;
  final double? rating;
  final int? ratingCount;

  /// Each crash or ANR cluster's label, by id.
  final Map<String, String>? errors;
  final double? crashRate;
  final double? anrRate;
  final bool vitalsRead;

  /// This digest with every part [fresh] read replacing its own. Review ids
  /// are kept together, so one that drops out of a store's page and comes
  /// back is not new.
  StoreDigest mergedWith(StoreDigest fresh) {
    final reviews = fresh.reviews == null
        ? this.reviews
        : _newestReviews({...?this.reviews, ...?fresh.reviews});
    return StoreDigest(
      releases: fresh.releases ?? releases,
      reviews: reviews,
      rating: fresh.rating ?? rating,
      ratingCount: fresh.rating == null ? ratingCount : fresh.ratingCount,
      errors: fresh.errors ?? errors,
      crashRate: fresh.vitalsRead ? fresh.crashRate : crashRate,
      anrRate: fresh.vitalsRead ? fresh.anrRate : anrRate,
      vitalsRead: vitalsRead || fresh.vitalsRead,
    );
  }

  static Map<String, ReviewDigest> _newestReviews(
    Map<String, ReviewDigest> all,
  ) {
    if (all.length <= kDigestReviewLimit) return all;
    final sorted = all.entries.toList()
      ..sort((a, b) => b.value.at.compareTo(a.value.at));
    return Map.fromEntries(sorted.take(kDigestReviewLimit));
  }

  Map<String, Object?> toJson() => {
    if (releases case final releases?)
      'releases': {
        for (final MapEntry(:key, :value) in releases.entries)
          key: value.toJson(),
      },
    if (reviews case final reviews?)
      'reviews': {
        for (final MapEntry(:key, :value) in reviews.entries)
          key: [value.at.toUtc().toIso8601String(), value.rating],
      },
    'rating': ?rating,
    'ratingCount': ?ratingCount,
    'errors': ?errors,
    'crashRate': ?crashRate,
    'anrRate': ?anrRate,
    if (vitalsRead) 'vitalsRead': true,
  };

  factory StoreDigest.fromJson(Map<String, Object?> json) {
    Map<String, Object?>? map(Object? value) =>
        value == null ? null : (value as Map).cast<String, Object?>();
    return StoreDigest(
      releases: map(json['releases'])?.map(
        (key, value) =>
            MapEntry(key, ReleaseDigest.fromJson(map(value) ?? const {})),
      ),
      reviews: map(json['reviews'])?.map((key, value) {
        final pair = value! as List;
        return MapEntry(key, (
          at: DateTime.parse(pair[0]! as String),
          rating: (pair[1]! as num).toInt(),
        ));
      }),
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: (json['ratingCount'] as num?)?.toInt(),
      errors: map(json['errors'])?.cast<String, String>(),
      crashRate: (json['crashRate'] as num?)?.toDouble(),
      anrRate: (json['anrRate'] as num?)?.toDouble(),
      vitalsRead: json['vitalsRead'] == true,
    );
  }
}

/// Which release a state belongs to across reads. An App Store version
/// keeps its key while builds are attached to it; a test build and a Play
/// release are their build.
String releaseKey(StoreKind store, StoreRelease release) =>
    store == StoreKind.appStore && release.track != kTestFlightTrack
    ? '${release.track}|${release.version}'
    : '${release.track}|${release.version}|${release.build ?? ''}';

const String kTestFlightTrack = 'TestFlight';

/// What changed between [before] and [after], the next read's digest, in
/// the order a person reads them. A part either side never read says
/// nothing: the first read of anything is not news.
List<StoreChange> storeChanges(
  StoreKind store,
  StoreDigest before,
  StoreDigest after,
) => [
  ..._releaseChanges(store, before.releases, after.releases),
  ?_reviewChange(before.reviews, after.reviews),
  ?_ratingChange(before, after),
  ..._errorChanges(before.errors, after.errors),
  ..._stabilityChanges(before, after),
];

/// `iOS`, `macOS`, `Android`: read off the App Store tracks [snapshot] has.
String storePlatform(StoreAppSnapshot snapshot) => snapshot.platform;

bool _testTrack(StoreKind store, String track) => store == StoreKind.appStore
    ? track == kTestFlightTrack
    : track != 'production';

/// Moves into these are the store tidying up, not news.
const _quietStates = {ReleaseState.expired, ReleaseState.superseded};

List<StoreChange> _releaseChanges(
  StoreKind store,
  Map<String, ReleaseDigest>? before,
  Map<String, ReleaseDigest>? after,
) {
  if (before == null || after == null) return const [];
  final changes = <StoreChange>[];
  for (final MapEntry(:key, value: now) in after.entries) {
    if (_quietStates.contains(now.state)) continue;
    final was = before[key];
    final test = _testTrack(store, now.track);
    final name = _releaseName(store, now);
    final attention = _wantsAttention(now);
    if (was == null) {
      changes.add(
        StoreChange(
          kind: test ? StoreChangeKind.build : StoreChangeKind.release,
          text: test
              ? 'New ${_buildEvent(name, now) ?? '$name: ${stateWords(store, now)}'}'
              : 'New $name: ${stateWords(store, now)}',
          attention: attention,
        ),
      );
      continue;
    }
    final from = stateWords(store, was);
    final to = stateWords(store, now);
    if (from == to) continue;
    final processed = test && was.state == ReleaseState.processing;
    changes.add(
      StoreChange(
        kind: test ? StoreChangeKind.build : StoreChangeKind.release,
        text:
            (processed ? _buildEvent(name, now) : null) ?? '$name $from → $to',
        attention: attention,
      ),
    );
  }
  return changes;
}

/// A test build's processing outcome as one phrase, or null for any other
/// state.
String? _buildEvent(String name, ReleaseDigest build) => switch (build.state) {
  ReleaseState.processing => '$name processing',
  ReleaseState.testing => '$name processed',
  ReleaseState.rejected => '$name failed processing',
  _ => null,
};

bool _wantsAttention(ReleaseDigest release) =>
    release.state.needsAttention ||
    release.rawState == 'DEVELOPER_ACTION_NEEDED';

/// `1.34.4`, `TestFlight 1.34.4 (71)`, `internal 1.35.0 (72)`.
String _releaseName(StoreKind store, ReleaseDigest release) {
  final version = release.version.isEmpty
      ? 'build ${release.build ?? '?'}'
      : release.version;
  final main =
      release.track == 'App Store' ||
      (store == StoreKind.googlePlay && release.track == 'production');
  if (main) return version;
  final build = release.build;
  final withBuild = build == null || release.version.isEmpty
      ? version
      : '$version ($build)';
  return '${release.track} $withBuild';
}

/// The App Store's words for a version's state, where they say more than
/// [ReleaseState.label].
const Map<String, String> _appleWords = {
  'READY_FOR_SALE': 'Ready for sale',
  'READY_FOR_DISTRIBUTION': 'Ready for distribution',
  'PREORDER_READY_FOR_SALE': 'Ready for pre-order',
  'PENDING_DEVELOPER_RELEASE': 'Approved',
  'PENDING_APPLE_RELEASE': 'Approved',
  'METADATA_REJECTED': 'Metadata rejected',
  'INVALID_BINARY': 'Invalid binary',
  'DEVELOPER_ACTION_NEEDED': 'Developer action needed',
  'REMOVED_FROM_SALE': 'Removed from sale',
  'DEVELOPER_REMOVED_FROM_SALE': 'Removed from sale',
  'PREPARE_FOR_SUBMISSION': 'Prepare for submission',
  'READY_FOR_REVIEW': 'Ready for review',
  'DEVELOPER_REJECTED': 'Developer rejected',
};

/// How [release]'s state is said: `Ready for sale`, `Rolling out 20%`.
String stateWords(StoreKind store, ReleaseDigest release) {
  final share = release.rollout;
  final percent = share == null ? '' : ' ${_percent(share)}';
  if (release.state == ReleaseState.rollingOut) return 'Rolling out$percent';
  if (release.state == ReleaseState.halted) return 'Halted$percent';
  if (store == StoreKind.appStore) {
    final words = _appleWords[release.rawState];
    if (words != null) return words;
  }
  if (release.state != ReleaseState.unknown) return release.state.label;
  return _sentenceCase(release.rawState);
}

String _percent(double share) {
  final value = share * 100;
  return value == value.roundToDouble()
      ? '${value.round()}%'
      : '${value.toStringAsFixed(1)}%';
}

String _sentenceCase(String raw) {
  final words = raw
      .replaceFirst('RELEASE_LIFECYCLE_STATE_', '')
      .toLowerCase()
      .replaceAll('_', ' ')
      .trim();
  if (words.isEmpty) return 'Unknown';
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

StoreChange? _reviewChange(
  Map<String, ReviewDigest>? before,
  Map<String, ReviewDigest>? after,
) {
  if (before == null || after == null) return null;
  // One older than everything known before is one that came back into the
  // page, not one just written.
  final floor = before.isEmpty
      ? null
      : before.values.map((review) => review.at).reduce(_earlier);
  final fresh = [
    for (final MapEntry(:key, :value) in after.entries)
      if (!before.containsKey(key) &&
          (floor == null || !value.at.isBefore(floor)))
        value,
  ];
  if (fresh.isEmpty) return null;
  final lowest = fresh.map((review) => review.rating).reduce(math.min);
  final count = fresh.length;
  return StoreChange(
    kind: StoreChangeKind.reviews,
    text: count == 1
        ? '1 new review ($lowest★)'
        : '$count new reviews (lowest $lowest★)',
    attention: lowest <= 2,
  );
}

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

StoreChange? _ratingChange(StoreDigest before, StoreDigest after) {
  final (from, to) = (before.rating, after.rating);
  if (from == null || to == null) return null;
  if ((to - from).abs() < kRatingMoveWorthTelling - 1e-9) return null;
  var digits = 1;
  while (digits < 3 &&
      from.toStringAsFixed(digits) == to.toStringAsFixed(digits)) {
    digits++;
  }
  return StoreChange(
    kind: StoreChangeKind.rating,
    text:
        'Rating ${from.toStringAsFixed(digits)} → ${to.toStringAsFixed(digits)}',
  );
}

List<StoreChange> _errorChanges(
  Map<String, String>? before,
  Map<String, String>? after,
) {
  if (before == null || after == null) return const [];
  return [
    for (final MapEntry(:key, :value) in after.entries)
      if (!before.containsKey(key))
        StoreChange(kind: StoreChangeKind.errorNew, text: 'New $value'),
    for (final MapEntry(:key, :value) in before.entries)
      if (!after.containsKey(key))
        StoreChange(
          kind: StoreChangeKind.errorResolved,
          text: 'No longer reported: $value',
        ),
  ];
}

String _issueLabel(StoreErrorIssue issue) {
  final kind = issue.kind == StoreErrorKind.anr ? 'ANR' : 'crash';
  final cause = issue.cause.trim();
  final location = issue.location.trim();
  final what = [
    if (cause.isNotEmpty) cause,
    if (location.isNotEmpty) 'in $location',
  ].join(' ');
  return what.isEmpty ? kind : '$kind: $what';
}

List<StoreChange> _stabilityChanges(StoreDigest before, StoreDigest after) {
  if (!before.vitalsRead || !after.vitalsRead) return const [];
  StoreChange? jump(String what, double? from, double? to, double floor) {
    if (from == null || to == null || from <= 0) return null;
    if (to < floor || to < from * 2) return null;
    return StoreChange(
      kind: StoreChangeKind.stability,
      text: '$what rate ${_rate(from)} → ${_rate(to)}',
      attention: true,
    );
  }

  return [
    ?jump('Crash', before.crashRate, after.crashRate, kCrashRateWorthTelling),
    ?jump('ANR', before.anrRate, after.anrRate, kAnrRateWorthTelling),
  ];
}

String _rate(double rate) => '${(rate * 100).toStringAsFixed(2)}%';
