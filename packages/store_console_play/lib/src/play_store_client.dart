import 'package:googleapis/androidpublisher/v3.dart';
// ignore: deprecated_member_use
import 'package:googleapis/storage/v1.dart' show StorageApi;
import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

import 'play_account.dart';
import 'play_auth.dart';
import 'play_error_issues.dart';
import 'play_errors.dart';
import 'play_icon.dart';
import 'play_mapping.dart';
import 'play_reporting.dart';
import 'play_reports_bucket.dart';

const int _downloadDays = 14;

/// Google Play, read-only.
class PlayStoreClient implements StoreClient, StoreErrorIssueSource {
  /// [httpClient] is the transport the token and every call go through; a
  /// test hands in a fake.
  PlayStoreClient(
    PlayAccount account, {
    http.Client? httpClient,
    DateTime Function()? now,
  }) : this._(account, httpClient ?? http.Client(), now ?? DateTime.now);

  PlayStoreClient._(this.account, http.Client transport, this._now)
    : _transport = transport,
      _auth = PlayAuth(account, transport);

  final PlayAccount account;

  /// The plain transport under [_auth]: the public store page is read
  /// through it, so no request there carries the account's token. Closed
  /// with [_auth].
  final http.Client _transport;
  final PlayAuth _auth;
  final DateTime Function() _now;

  @override
  StoreKind get store => StoreKind.googlePlay;

  DateTime get _today {
    final now = _now().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  @override
  Future<List<StoreApp>> listApps() => playGuarded(() async {
    final names = <String, String?>{
      for (final packageName in account.packageNames)
        if (packageName.trim().isNotEmpty) packageName.trim(): null,
    };
    try {
      final found = await PlayReporting(await _auth.client()).searchApps();
      for (final app in found) {
        names[app.packageName] = app.displayName ?? names[app.packageName];
      }
    } on Object catch (error) {
      // The typed packages stand when the account may not search; a refused
      // key or a dead connection must still be said.
      final failure = playFailure(error, area: PlayArea.reporting);
      if (failure.kind != StoreFailure.permission) throw failure;
      if (names.isEmpty) {
        // Releases and reviews go through another API, which may well answer
        // for a package named outright.
        throw StoreException(
          failure.kind,
          '${failure.message} Or type the package names in Settings → '
          'Stores, so releases and reviews are read without finding the apps '
          'first.',
        );
      }
    }
    final apps = [
      for (final MapEntry(key: packageName, value: name) in names.entries)
        StoreApp(
          store: StoreKind.googlePlay,
          id: packageName,
          bundleId: packageName,
          name: name ?? packageName,
        ),
    ];
    return apps..sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
  });

  @override
  // Never through an edit: opening one invalidates an edit a release
  // pipeline has open under the same service account.
  Future<List<StoreRelease>> releases(StoreApp app) => playGuarded(() async {
    final releases = AndroidPublisherApi(
      await _auth.client(),
    ).applications.tracks.releases;
    final tracks = await Future.wait([
      for (final track in playTracks)
        releases
            .list('applications/${app.id}/tracks/$track')
            .then(
              (response) =>
                  releasesFromSummaries(track, response.releases ?? const []),
            )
            .catchError(
              // A track the app has never used is not there to read. Google
              // says so with a 404, or — seen 2026-10-01 on beta and alpha —
              // with an empty 200, which googleapis' generated `list` casts
              // to a JSON map and throws a TypeError on. Either is an empty
              // track; before this, one unused track failed every release.
              (Object _) => const <StoreRelease>[],
              test: (error) =>
                  (error is DetailedApiRequestError && error.status == 404) ||
                  error is TypeError,
            ),
    ]);
    return [for (final track in tracks) ...track];
  });

  /// The API only returns reviews written or changed in the last week, and
  /// only those with text.
  @override
  ///
  /// A 404 here is "no reviews to list", not "no such app": Google answered it
  /// for com.popupbits.karmashala on 2026-10-01 while the same call's
  /// releases read fine, an app with no public reviews yet. A package that
  /// truly does not exist is said by its releases, which 404 too.
  Future<List<StoreReview>> reviews(StoreApp app) => playGuarded(() async {
    try {
      final response = await AndroidPublisherApi(
        await _auth.client(),
      ).reviews.list(app.id, maxResults: 100);
      return reviewsFrom(response.reviews ?? const []);
    } on DetailedApiRequestError catch (error) {
      if (error.status == 404) return const <StoreReview>[];
      rethrow;
    }
  }, area: PlayArea.reviews);

  @override
  Future<RatingSummary> rating(StoreApp app) => playGuarded(() async {
    final bucket = await _bucket('to see the rating.');
    final month = _today;
    final table =
        await bucket.read(ratingsObject(app.id, month)) ??
        await bucket.read(ratingsObject(app.id, previousMonth(month)));
    if (table == null) throw playStatusFailure(404, area: PlayArea.bucket);
    final average = latestAverageRating(table);
    if (average == null) {
      throw const StoreException(
        StoreFailure.notSupported,
        'Google Play has not reported a rating for this app yet.',
      );
    }
    return RatingSummary(average: average);
  }, area: PlayArea.bucket);

  @override
  Future<VitalsSummary> vitals(StoreApp app) => playGuarded(() async {
    final reporting = PlayReporting(await _auth.client());
    final crash = _vitals(reporting, app.id, VitalsMetric.crash);
    final anr = _vitals(reporting, app.id, VitalsMetric.anr);
    final (crashed, notResponding) = (await crash, await anr);
    // A null rate means the store had too little data; a failed call must not
    // be read as that, so it is said instead.
    final failure = crashed.failure ?? notResponding.failure;
    if (failure != null) throw failure;
    final window = crashed.window ?? notResponding.window;
    if (window == null) {
      throw playStatusFailure(null, area: PlayArea.reporting);
    }
    return VitalsSummary(
      from: window.from,
      to: window.to,
      crashRate: crashed.rate,
      anrRate: notResponding.rate,
    );
  }, area: PlayArea.reporting);

  @override
  Future<DownloadSeries> downloads(StoreApp app) => playGuarded(() async {
    final bucket = await _bucket('to see installs.');
    final to = _today;
    final from = to.subtract(const Duration(days: _downloadDays));
    final months = {
      DateTime.utc(from.year, from.month),
      DateTime.utc(to.year, to.month),
    };
    final days = <DateTime, int>{};
    var found = false;
    for (final month in months) {
      final table = await bucket.read(installsObject(app.id, month));
      if (table == null) continue;
      found = true;
      days.addAll(dailyInstalls(table, from: from, to: to));
    }
    // No file at all is a wrong bucket or package, not fourteen quiet days.
    if (!found) throw playStatusFailure(404, area: PlayArea.bucket);
    return DownloadSeries(
      unit: 'Installs',
      days: [
        for (final day in days.keys.toList()..sort())
          DailyCount(day, days[day]!),
      ],
    );
  }, area: PlayArea.bucket);

  @override
  Future<List<StoreErrorIssue>> errorIssues(StoreApp app) =>
      playGuarded(() async {
        final reporting = PlayReporting(await _auth.client());
        final now = _now().toUtc();
        final end = DateTime.utc(now.year, now.month, now.day, now.hour);
        final start = end.subtract(errorIssueWindow);
        final issues = parseErrorIssues(
          await reporting.searchErrorIssues(
            app.id,
            start: start,
            end: end,
            pageSize: errorIssueCount,
          ),
        );
        // A sample that cannot be read leaves its issue without a trace; it
        // does not take the list with it.
        final sampled = await Future.wait([
          for (final (i, issue) in issues.indexed)
            if (i >= errorSampleCount)
              Future.value(issue)
            else
              reporting
                  .searchErrorReports(app.id, issue.id, start: start, end: end)
                  .then((page) => withSampleReport(issue, page))
                  .catchError((Object _) => issue),
        ]);
        return sampled;
      }, area: PlayArea.reporting);

  @override
  Future<StoreIconImage?> icon(StoreApp app) => playIcon(_transport, app.id);

  @override
  void close() => _auth.close();

  Future<PlayReportsBucket> _bucket(String purpose) async {
    final name = normaliseBucket(account.reportsBucket);
    if (name == null) {
      throw StoreException(
        StoreFailure.notConfigured,
        'Add your reports bucket in Settings → Stores $purpose',
      );
    }
    return PlayReportsBucket(StorageApi(await _auth.client()), name);
  }

  Future<_Vitals> _vitals(
    PlayReporting reporting,
    String packageName,
    VitalsMetric metric,
  ) async {
    try {
      // Reports run two days behind when the set does not say how fresh it is.
      final end =
          await reporting.dailyFreshness(packageName, metric) ??
          _today.subtract(const Duration(days: 2));
      final start = end.subtract(const Duration(days: vitalsDays));
      final rate = await reporting.rate(
        packageName,
        metric,
        start: start,
        end: end,
      );
      return (window: (from: start, to: end), rate: rate, failure: null);
    } on Object catch (error) {
      return (
        window: null,
        rate: null,
        failure: playFailure(error, area: PlayArea.reporting),
      );
    }
  }
}

typedef _Vitals = ({
  ({DateTime from, DateTime to})? window,
  double? rate,
  StoreException? failure,
});
