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
    this.errorIssues,
  });

  final StoreApp app;
  final Reading<List<StoreRelease>> releases;
  final Reading<List<StoreReview>> reviews;
  final Reading<RatingSummary> rating;
  final Reading<VitalsSummary> vitals;
  final Reading<DownloadSeries> downloads;

  /// Null for a store that does not group its crashes into issues.
  final Reading<List<StoreErrorIssue>>? errorIssues;

  /// What a user has: the first live release, else one rolling out, else a
  /// halted one — a paused phased release is still on sale.
  StoreRelease? get live {
    final all = releases.valueOrNull ?? const <StoreRelease>[];
    for (final state in const [
      ReleaseState.live,
      ReleaseState.rollingOut,
      ReleaseState.halted,
    ]) {
      for (final release in all) {
        if (release.state == state) return release;
      }
    }
    return null;
  }

  /// Releases somebody is waiting on or has to act on, those to act on first.
  /// One a newer release on its track has gone live past is history, not
  /// work: a rejected 1.0 under a live 1.1 is not stuck.
  List<StoreRelease> get pending {
    final all = releases.valueOrNull ?? const <StoreRelease>[];
    bool overtaken(StoreRelease release) => all.any(
      (other) =>
          other.track == release.track &&
          (other.state == ReleaseState.live ||
              other.state == ReleaseState.rollingOut) &&
          other.isNewerThan(release),
    );
    final open = [
      for (final release in all)
        if ((release.state.inFlight || release.state.needsAttention) &&
            !overtaken(release))
          release,
    ];
    return [
      ...open.where((release) => release.state.needsAttention),
      ...open.where((release) => !release.state.needsAttention),
    ];
  }

  /// This reading with what [previous] knew that a store does not say again:
  /// the rating's history.
  StoreAppSnapshot carriedFrom(StoreAppSnapshot? previous) {
    final rating = this.rating;
    if (rating is! ReadingValue<RatingSummary>) return this;
    return StoreAppSnapshot(
      app: app,
      releases: releases,
      reviews: reviews,
      rating: ReadingValue(
        rating.value.carriedFrom(
          previous?.rating.valueOrNull,
          rating.checkedAt,
        ),
        rating.checkedAt,
      ),
      vitals: vitals,
      downloads: downloads,
      errorIssues: errorIssues,
    );
  }

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
    if (errorIssues case final issues?)
      'errorIssues': issues.toJson(
        (value) => [for (final issue in value) issue.toJson()],
      ),
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
      errorIssues: json['errorIssues'] == null
          ? null
          : Reading.fromJson(
              map(json['errorIssues']),
              (value) => maps(value).map(StoreErrorIssue.fromJson).toList(),
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
    final errorIssues = switch (client) {
      final StoreErrorIssueSource source => _read(
        () => source.errorIssues(app),
      ),
      _ => null,
    };
    return StoreAppSnapshot(
      app: app,
      releases: await releases,
      reviews: await reviews,
      rating: await rating,
      vitals: await vitals,
      downloads: await downloads,
      errorIssues: await errorIssues,
    );
  }

  /// [app]'s icon: a value of null when the store has no public page for it,
  /// missing when it could not be read.
  Future<Reading<StoreIconImage?>> icon(StoreApp app) {
    final client = clients.firstWhere((client) => client.store == app.store);
    return _read(() => client.icon(app));
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
