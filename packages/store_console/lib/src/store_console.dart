import 'domain.dart';
import 'reading.dart';
import 'store_client.dart';

/// Everything read about one app, each part with its own outcome.
class StoreAppSnapshot {
  const StoreAppSnapshot({
    required this.app,
    required this.releases,
    required this.reviews,
    required this.rating,
    required this.vitals,
    required this.downloads,
  });

  final StoreApp app;
  final Reading<List<StoreRelease>> releases;
  final Reading<List<StoreReview>> reviews;
  final Reading<RatingSummary> rating;
  final Reading<VitalsSummary> vitals;
  final Reading<DownloadSeries> downloads;

  /// What a user has: the first live or rolling-out release.
  StoreRelease? get live {
    for (final release in releases.valueOrNull ?? const <StoreRelease>[]) {
      if (release.state == ReleaseState.live ||
          release.state == ReleaseState.rollingOut) {
        return release;
      }
    }
    return null;
  }

  /// Releases somebody is waiting on or has to act on.
  List<StoreRelease> get pending => [
    for (final release in releases.valueOrNull ?? const <StoreRelease>[])
      if (release.state.inFlight || release.state.needsAttention) release,
  ];

  Map<String, Object?> toJson() => {
    'app': app.toJson(),
    'releases': releases.toJson(
      (value) => [for (final release in value) release.toJson()],
    ),
    'reviews': reviews.toJson(
      (value) => [for (final review in value) review.toJson()],
    ),
    'rating': rating.toJson((value) => value.toJson()),
    'vitals': vitals.toJson((value) => value.toJson()),
    'downloads': downloads.toJson((value) => value.toJson()),
  };

  factory StoreAppSnapshot.fromJson(Map<String, Object?> json) {
    Map<String, Object?> map(Object? value) =>
        (value! as Map).cast<String, Object?>();
    List<Map<String, Object?>> maps(Object? value) =>
        (value! as List).map(map).toList();
    return StoreAppSnapshot(
      app: StoreApp.fromJson(map(json['app'])),
      releases: Reading.fromJson(
        map(json['releases']),
        (value) => maps(value).map(StoreRelease.fromJson).toList(),
      ),
      reviews: Reading.fromJson(
        map(json['reviews']),
        (value) => maps(value).map(StoreReview.fromJson).toList(),
      ),
      rating: Reading.fromJson(
        map(json['rating']),
        (value) => RatingSummary.fromJson(map(value)),
      ),
      vitals: Reading.fromJson(
        map(json['vitals']),
        (value) => VitalsSummary.fromJson(map(value)),
      ),
      downloads: Reading.fromJson(
        map(json['downloads']),
        (value) => DownloadSeries.fromJson(map(value)),
      ),
    );
  }
}

/// What one store said when asked for its apps.
class StoreAppsReading {
  const StoreAppsReading(this.store, this.apps);

  final StoreKind store;
  final Reading<List<StoreApp>> apps;
}

/// Several stores read as one. A store that fails does not take the others
/// with it, and a reading that fails does not take the app's other readings.
class StoreConsole {
  StoreConsole(this.clients, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final List<StoreClient> clients;
  final DateTime Function() _now;

  Future<List<StoreAppsReading>> listApps() => Future.wait([
    for (final client in clients)
      _read(
        client.listApps,
      ).then((apps) => StoreAppsReading(client.store, apps)),
  ]);

  Future<StoreAppSnapshot> snapshot(StoreApp app) async {
    final client = clients.firstWhere((client) => client.store == app.store);
    final releases = _read(() => client.releases(app));
    final reviews = _read(() => client.reviews(app));
    final rating = _read(() => client.rating(app));
    final vitals = _read(() => client.vitals(app));
    final downloads = _read(() => client.downloads(app));
    return StoreAppSnapshot(
      app: app,
      releases: await releases,
      reviews: await reviews,
      rating: await rating,
      vitals: await vitals,
      downloads: await downloads,
    );
  }

  void close() {
    for (final client in clients) {
      client.close();
    }
  }

  Future<Reading<T>> _read<T>(Future<T> Function() call) async {
    try {
      return ReadingValue<T>(await call(), _now());
    } on StoreException catch (error) {
      return ReadingMissing<T>(error.kind, error.message, _now());
    } on Object catch (error) {
      // A client that let something else through still must not blank the
      // app; the type is said, the text is not, since it may quote a request.
      return ReadingMissing<T>(
        StoreFailure.shape,
        'The store answered in a way this could not read '
        '(${error.runtimeType}).',
        _now(),
      );
    }
  }
}
