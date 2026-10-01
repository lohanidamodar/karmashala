import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

import 'apple_api_key.dart';
import 'apple_documents.dart';
import 'apple_http.dart';
import 'apple_states.dart';
import 'apple_token.dart';
import 'sales_report.dart';

const _host = 'api.appstoreconnect.apple.com';
const _downloadDays = 14;
const _maxPages = 20;

/// An icon is never worth holding a refresh up for.
const _iconTimeout = Duration(seconds: 10);

/// A day Apple had no report for is asked about again after this long.
const _absentFor = Duration(minutes: 30);

/// The App Store, read-only.
class AppleStoreClient implements StoreClient {
  AppleStoreClient(
    this.key, {
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _http = AppleHttp(
      httpClient ?? http.Client(),
      AppleTokenSigner(key, _now).token,
      _now,
    );
  }

  final AppleApiKey key;
  final DateTime Function() _now;
  late final AppleHttp _http;

  // A daily report covers the whole vendor, so every app shares one fetch.
  final _reports = <String, Future<Map<String, int>?>>{};
  final _absentSince = <String, DateTime>{};

  @override
  StoreKind get store => StoreKind.appStore;

  Future<JsonMap> _get(
    String path,
    Map<String, String> query, {
    required String what,
  }) => _http.getJson(Uri.https(_host, path, query), what: what);

  @override
  Future<List<StoreApp>> listApps() async {
    const what = 'your apps';
    final apps = <StoreApp>[];
    var page = await _get('/v1/apps', const {
      'fields[apps]': 'name,bundleId',
      'limit': '200',
    }, what: what);
    for (var pages = 1; ; pages++) {
      apps.addAll(parseApps(page));
      final next = nextPage(page);
      // The token is only ever sent to Apple's own host.
      if (next == null || next.host != _host || pages >= _maxPages) break;
      page = await _http.getJson(next, what: what);
    }
    return apps;
  }

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async {
    final both = await Future.wait([_versions(app), _builds(app)]);
    return orderReleases(both.expand((releases) => releases));
  }

  // The endpoint cannot sort, so a full page is read and the newest kept.
  Future<List<StoreRelease>> _versions(StoreApp app) async => parseVersions(
    await _get('/v1/apps/${app.id}/appStoreVersions', const {
      'fields[appStoreVersions]':
          'versionString,appVersionState,appStoreState,platform,createdDate,'
          'appStoreVersionPhasedRelease,build',
      'fields[appStoreVersionPhasedReleases]':
          'phasedReleaseState,currentDayNumber',
      'fields[builds]': 'version',
      'include': 'appStoreVersionPhasedRelease,build',
      'limit': '200',
    }, what: 'versions'),
  );

  Future<List<StoreRelease>> _builds(StoreApp app) async {
    try {
      return parseBuilds(
        await _get('/v1/builds', {
          'filter[app]': app.id,
          'sort': '-uploadedDate',
          'limit': '$shownBuilds',
          'fields[builds]':
              'version,uploadedDate,processingState,expired,preReleaseVersion',
          'fields[preReleaseVersions]': 'version',
          'include': 'preReleaseVersion',
        }, what: 'TestFlight builds'),
      );
    } on StoreException catch (error) {
      // A key without TestFlight access still shows the App Store versions.
      if (error.kind == StoreFailure.permission) return const [];
      rethrow;
    }
  }

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async => parseReviews(
    await _get('/v1/apps/${app.id}/customerReviews', const {
      'sort': '-createdDate',
      'limit': '50',
      'include': 'response',
    }, what: 'reviews'),
  );

  /// From the public lookup: App Store Connect has no icon field. Asked by
  /// the App Store id on the US storefront, then by bundle id, so an app the
  /// US store does not sell is still found where the lookup's default
  /// storefront has it.
  @override
  Future<StoreIconImage?> icon(StoreApp app) async {
    Future<Uri?> lookup(Map<String, String> query) async => parseLookupIcon(
      await _http.getJson(
        Uri.https('itunes.apple.com', '/lookup', query),
        what: 'the icon',
        authorized: false,
        timeout: _iconTimeout,
      ),
    );
    final source =
        await lookup({'id': app.id, 'country': 'us'}) ??
        (app.bundleId.isEmpty
            ? null
            : await lookup({'bundleId': app.bundleId}));
    if (source == null) return null;
    final response = await _http.get(
      source,
      what: 'the icon',
      authorized: false,
      accept: 'image/*',
      absentOn404: true,
      timeout: _iconTimeout,
    );
    if (response == null) return null;
    final type = (response.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    if (!type.startsWith('image/') || response.bodyBytes.isEmpty) {
      throw shapeFailure('the icon');
    }
    return StoreIconImage(
      source: source,
      bytes: response.bodyBytes,
      contentType: type,
    );
  }

  /// The rating on the United States storefront, from the public lookup:
  /// App Store Connect has no rating of its own to give.
  @override
  Future<RatingSummary> rating(StoreApp app) async {
    final rating = parseLookupRating(
      await _http.getJson(
        Uri.https('itunes.apple.com', '/lookup', {
          'id': app.id,
          'country': 'us',
        }),
        what: 'the rating',
        authorized: false,
      ),
    );
    if (rating != null) return rating;
    throw const StoreException(
      StoreFailure.notSupported,
      'No rating on the US storefront yet.',
    );
  }

  @override
  Future<VitalsSummary> vitals(StoreApp app) async =>
      throw const StoreException(
        StoreFailure.notSupported,
        'The App Store does not publish crash rates through its API.',
      );

  @override
  Future<DownloadSeries> downloads(StoreApp app) async {
    final vendor = key.vendorNumber?.trim() ?? '';
    if (vendor.isEmpty) {
      throw const StoreException(
        StoreFailure.notConfigured,
        'Add your vendor number in Settings → Stores to see downloads.',
      );
    }
    final today = _now().toUtc();
    final days = [
      for (var back = _downloadDays; back >= 1; back--)
        DateTime.utc(today.year, today.month, today.day - back),
    ];
    final wanted = {for (final day in days) _dateKey(day)};
    _reports.removeWhere((date, _) => !wanted.contains(date));
    _absentSince.removeWhere((date, _) => !wanted.contains(date));

    final reports = await Future.wait([
      for (final day in days) _report(vendor, _dateKey(day)),
    ]);
    return DownloadSeries(
      unit: 'Units',
      days: [
        for (final (index, report) in reports.indexed)
          if (report != null)
            DailyCount(days[index], math.max(0, report[app.id] ?? 0)),
      ],
    );
  }

  /// Units by app id for one day, or null when Apple has no report for it.
  Future<Map<String, int>?> _report(String vendor, String date) {
    final absentSince = _absentSince[date];
    if (absentSince != null && _now().difference(absentSince) >= _absentFor) {
      _absentSince.remove(date);
      _reports.remove(date);
    }
    final cached = _reports[date];
    if (cached != null) return cached;
    final fetch = _fetchReport(vendor, date);
    _reports[date] = fetch;
    // A failure is never remembered; the next ask tries again.
    unawaited(
      fetch.then<void>(
        (units) {
          if (units == null) _absentSince[date] = _now();
        },
        onError: (Object _) {
          if (identical(_reports[date], fetch)) _reports.remove(date);
        },
      ),
    );
    return fetch;
  }

  Future<Map<String, int>?> _fetchReport(String vendor, String date) async {
    final response = await _http.get(
      Uri.https(_host, '/v1/salesReports', {
        'filter[frequency]': 'DAILY',
        'filter[reportType]': 'SALES',
        'filter[reportSubType]': 'SUMMARY',
        'filter[vendorNumber]': vendor,
        'filter[reportDate]': date,
        'filter[version]': '1_0',
      }),
      what: 'sales reports',
      accept: 'application/a-gzip, application/json',
      role: 'Sales, Finance or Admin',
      absentOn404: true,
    );
    if (response == null) return null;
    return parseSalesUnits(decodeSalesReport(response.bodyBytes));
  }

  @override
  void close() => _http.close();
}

String _dateKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';
