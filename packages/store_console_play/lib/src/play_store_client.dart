import 'package:googleapis/androidpublisher/v3.dart';
// ignore: deprecated_member_use
import 'package:googleapis/storage/v1.dart' show StorageApi;
import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

import 'play_account.dart';
import 'play_auth.dart';
import 'play_errors.dart';
import 'play_mapping.dart';
import 'play_reporting.dart';
import 'play_reports_bucket.dart';

const int _downloadDays = 14;

/// Google Play, read-only.
class PlayStoreClient implements StoreClient {
  /// [httpClient] is the transport the token and every call go through; a
  /// test hands in a fake.
  PlayStoreClient(
    this.account, {
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _auth = PlayAuth(account, httpClient ?? http.Client()),
       _now = now ?? DateTime.now;

  final PlayAccount account;
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
      final failure = playFailure(error);
      if (names.isEmpty || failure.kind != StoreFailure.permission) {
        throw failure;
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
  Future<List<StoreRelease>> releases(StoreApp app) => playGuarded(() async {
    final edits = AndroidPublisherApi(await _auth.client()).edits;
    final editId = (await edits.insert(AppEdit(), app.id)).id;
    if (editId == null) throw playStatusFailure(null);
    try {
      final tracks = await edits.tracks.list(app.id, editId);
      return releasesFromTracks(tracks.tracks ?? const []);
    } finally {
      try {
        await edits.delete(app.id, editId);
      } on Object {
        // An edit left behind expires by itself.
      }
    }
  });

  /// The API only returns reviews written or changed in the last week, and
  /// only those with text.
  @override
  Future<List<StoreReview>> reviews(StoreApp app) => playGuarded(() async {
    final response = await AndroidPublisherApi(
      await _auth.client(),
    ).reviews.list(app.id, maxResults: 100);
    return reviewsFrom(response.reviews ?? const []);
  });

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
    final window = crashed.window ?? notResponding.window;
    if (window == null) throw crashed.failure ?? notResponding.failure!;
    return VitalsSummary(
      from: window.from,
      to: window.to,
      crashRate: crashed.rate,
      anrRate: notResponding.rate,
    );
  });

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
      return (window: null, rate: null, failure: playFailure(error));
    }
  }
}

typedef _Vitals = ({
  ({DateTime from, DateTime to})? window,
  double? rate,
  StoreException? failure,
});
