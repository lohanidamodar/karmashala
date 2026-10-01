import 'package:store_console/store_console.dart';

final DateTime fixtureCheckedAt = DateTime.utc(2026, 9, 30, 8);

StoreApp storeApp(StoreKind store, String bundleId, {String? name}) => StoreApp(
  store: store,
  id: store == StoreKind.appStore ? 'id-$bundleId' : bundleId,
  bundleId: bundleId,
  name: name ?? bundleId,
);

StoreRelease storeRelease(
  ReleaseState state, {
  String version = '1.0.0',
  String track = 'production',
  double? rolloutFraction,
}) => StoreRelease(
  track: track,
  version: version,
  state: state,
  rawState: state.name,
  rolloutFraction: rolloutFraction,
);

/// Everything read; [releases] decides where the app stands.
StoreAppSnapshot storeSnapshot(
  StoreApp app, {
  List<StoreRelease> releases = const [],
  Reading<RatingSummary>? rating,
  Reading<DownloadSeries>? downloads,
}) => StoreAppSnapshot(
  app: app,
  releases: ReadingValue(releases, fixtureCheckedAt),
  reviews: ReadingValue([
    StoreReview(
      id: 'r1',
      rating: 4,
      title: 'Solid',
      body: 'Does what it says.',
      createdAt: DateTime.utc(2026, 9, 28),
      author: 'Asha',
      reply: 'Thank you.',
    ),
  ], fixtureCheckedAt),
  rating:
      rating ??
      ReadingValue(
        const RatingSummary(average: 4.6, count: 1200),
        fixtureCheckedAt,
      ),
  vitals: ReadingMissing(
    StoreFailure.notSupported,
    'The App Store publishes no crash rate.',
    fixtureCheckedAt,
  ),
  downloads:
      downloads ??
      ReadingValue(
        DownloadSeries(
          unit: 'Units',
          days: [
            for (var day = 1; day <= 14; day++)
              DailyCount(DateTime.utc(2026, 9, day), day * 10),
          ],
        ),
        fixtureCheckedAt,
      ),
);
