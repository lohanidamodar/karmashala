import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

import 'apple_api_key.dart';
import 'apple_documents.dart';
import 'apple_http.dart';
import 'apple_states.dart';
import 'apple_token.dart';
import 'sales_ledger.dart';
import 'sales_report.dart';

const _host = 'api.appstoreconnect.apple.com';
const _downloadDays = 14;
const _maxPages = 20;

/// An icon is never worth holding a refresh up for.
const _iconTimeout = Duration(seconds: 10);

/// The whole icon lookup, every request together; under the server's own
/// per-icon budget so this client stops its own requests first.
const _iconBudget = Duration(seconds: 20);

/// A build still processing has no icon yet, so a few are read.
const _iconBuilds = 5;

/// Longer than Apple takes to publish a period's report: a report still
/// missing this long after its period ended never comes — there were no
/// sales in it.
const _reportLag = Duration(days: 35);

/// A period Apple had no report for is asked about again after this long.
const _absentFor = Duration(minutes: 30);

/// The oldest year asked for: the App Store opened in 2008.
const _firstSalesYear = 2008;

/// The most the all-time count may add to a refresh. What was fetched by
/// then is kept, and the next refresh carries on from it.
const _allTimeBudget = Duration(seconds: 90);

/// The App Store, read-only.
class AppleStoreClient implements StoreClient, StoreInstallTotalSource {
  /// [salesLedger] is the sales reports of finished periods read before;
  /// whoever outlives this client hands it in so each is fetched once.
  AppleStoreClient(
    this.key, {
    http.Client? httpClient,
    DateTime Function()? now,
    AppleSalesLedger? salesLedger,
  }) : _now = now ?? DateTime.now,
       _ledger = salesLedger ?? AppleSalesLedger() {
    _http = AppleHttp(
      httpClient ?? http.Client(),
      AppleTokenSigner(key, _now).token,
      _now,
    );
  }

  final AppleApiKey key;
  final DateTime Function() _now;
  late final AppleHttp _http;
  final AppleSalesLedger _ledger;

  // A report covers the whole vendor, so every app shares one fetch.
  final _inFlight = <String, Future<Map<String, int>?>>{};

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

  /// The live version's marketing icon from the public lookup — by App Store
  /// id on the US storefront, then by bundle id — else, for an app the
  /// lookup does not know (never released, or not live), the newest build's
  /// icon from App Store Connect.
  @override
  Future<StoreIconImage?> icon(StoreApp app) async {
    final clock = Stopwatch()..start();
    Duration wait() {
      final left = _iconBudget - clock.elapsed;
      if (left <= Duration.zero) {
        throw StoreException(
          StoreFailure.network,
          'The icon was not found within ${_iconBudget.inSeconds} seconds.',
        );
      }
      return left < _iconTimeout ? left : _iconTimeout;
    }

    Future<Uri?> lookup(Map<String, String> query) async => parseLookupIcon(
      await _http.getJson(
        Uri.https('itunes.apple.com', '/lookup', query),
        what: 'the icon',
        authorized: false,
        timeout: wait(),
      ),
    );
    final source =
        await lookup({'id': app.id, 'country': 'us'}) ??
        (app.bundleId.isEmpty
            ? null
            : await lookup({'bundleId': app.bundleId})) ??
        await _buildIcon(app, wait());
    if (source == null) return null;
    // Never authorized: the image host is not Apple's API host.
    final response = await _http.get(
      source,
      what: 'the icon',
      authorized: false,
      accept: 'image/*',
      absentOn404: true,
      timeout: wait(),
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

  /// Null, not a failure, for a key that may not read builds.
  Future<Uri?> _buildIcon(StoreApp app, Duration timeout) async {
    try {
      return parseBuildIcon(
        await _http.getJson(
          Uri.https(_host, '/v1/builds', {
            'filter[app]': app.id,
            'sort': '-uploadedDate',
            'limit': '$_iconBuilds',
            'fields[builds]': 'iconAssetToken,uploadedDate',
          }),
          what: 'the icon',
          timeout: timeout,
        ),
      );
    } on StoreException catch (error) {
      if (error.kind == StoreFailure.permission) return null;
      rethrow;
    }
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
    _ledger.prune(today);

    final reports = await Future.wait([
      for (final day in days) _report(vendor, SalesFrequency.daily, day),
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

  /// First-time downloads since the app's first sale, from the Summary Sales
  /// Reports: a yearly report for each finished year, back to the first year
  /// Apple has none for; a monthly one for each finished month of this year;
  /// a daily one for each finished day of this month. A period whose report
  /// is not out yet is counted from the shorter reports inside it. Every
  /// finished period is fetched once and kept in the ledger.
  @override
  Future<InstallTotal> allTimeInstalls(StoreApp app) async {
    final vendor = key.vendorNumber?.trim() ?? '';
    if (vendor.isEmpty) {
      throw const StoreException(
        StoreFailure.notConfigured,
        'Add your vendor number in Settings → Stores to see all-time '
        'downloads.',
      );
    }
    try {
      return allTimeFromPeriods(
        await _salesHistory(vendor, app.id).timeout(_allTimeBudget),
      );
    } on TimeoutException {
      throw const StoreException(
        StoreFailure.network,
        'The sales history is still being read; the next refresh carries '
        'on from where this one stopped.',
      );
    }
  }

  Future<List<SalesPeriod>> _salesHistory(String vendor, String appId) async {
    final now = _now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    _ledger.prune(today);
    final found = <_Report>[];
    // Year by year, since the first year without a report ends the walk.
    for (var year = today.year - 1; year >= _firstSalesYear; year--) {
      final start = DateTime.utc(year);
      final report = await _report(vendor, SalesFrequency.yearly, start);
      if (report != null) {
        found.add((
          label: salesReportDate(SalesFrequency.yearly, start),
          last: _lastDay(start, 12),
          report: report,
        ));
        continue;
      }
      // Last year's yearly report may not be out yet in January.
      if (year == today.year - 1) {
        final months = await Future.wait([
          for (var month = 1; month <= 12; month++)
            _month(vendor, DateTime.utc(year, month), today),
        ]);
        final read = [for (final month in months) ...month];
        if (read.isNotEmpty) {
          found.addAll(read);
          continue;
        }
      }
      break;
    }
    final thisYear = await Future.wait([
      for (var month = 1; month < today.month; month++)
        _month(vendor, DateTime.utc(today.year, month), today),
      _days(vendor, DateTime.utc(today.year, today.month), today),
    ]);
    for (final part in thisYear) {
      found.addAll(part);
    }
    return [
      for (final period in found)
        (
          label: period.label,
          last: period.last,
          units: period.report[appId] ?? 0,
        ),
    ];
  }

  /// [month]'s report, else its finished days' reports when the monthly one
  /// is not out yet.
  Future<List<_Report>> _month(
    String vendor,
    DateTime month,
    DateTime today,
  ) async {
    final label = salesReportDate(SalesFrequency.monthly, month);
    final last = _lastDay(month, 1);
    final report = await _report(vendor, SalesFrequency.monthly, month);
    if (report != null) return [(label: label, last: last, report: report)];
    // Long past, a missing monthly report means no sales that month.
    if (today.difference(last) > _reportLag) return const [];
    return _days(vendor, month, today);
  }

  /// The reports of [month]'s days before [today] that Apple has out.
  Future<List<_Report>> _days(
    String vendor,
    DateTime month,
    DateTime today,
  ) async {
    final label = salesReportDate(SalesFrequency.monthly, month);
    final days = [
      for (
        var day = month;
        day.month == month.month && day.isBefore(today);
        day = DateTime.utc(day.year, day.month, day.day + 1)
      )
        day,
    ];
    final reports = await Future.wait([
      for (final day in days) _report(vendor, SalesFrequency.daily, day),
    ]);
    return [
      for (final (i, report) in reports.indexed)
        if (report != null) (label: label, last: days[i], report: report),
    ];
  }

  /// The last day of the [months] months from [start].
  static DateTime _lastDay(DateTime start, int months) =>
      DateTime.utc(start.year, start.month + months, 0);

  /// Units by app id for the finished period [frequency] at [start], or null
  /// when Apple has no report for it. Kept once read; a missing one is asked
  /// for again after [_absentFor], unless it is over a year past.
  Future<Map<String, int>?> _report(
    String vendor,
    SalesFrequency frequency,
    DateTime start,
  ) {
    final date = salesReportDate(frequency, start);
    final key = AppleSalesLedger.key(vendor, frequency, date);
    final held = _ledger.held(key);
    if (held != null) return Future.value(held);
    if (_ledger.absent(key, _now(), _absentFor)) return Future.value(null);
    final running = _inFlight[key];
    if (running != null) return running;
    final fetch = _fetchReport(vendor, frequency, date);
    _inFlight[key] = fetch;
    // A failure is never remembered; the next ask tries again.
    unawaited(
      fetch.then<void>(
        (units) {
          _inFlight.remove(key);
          if (units != null) {
            _ledger.keep(key, units);
          } else {
            final now = _now().toUtc();
            final last = switch (frequency) {
              SalesFrequency.daily => start,
              SalesFrequency.monthly => _lastDay(start, 1),
              SalesFrequency.yearly => _lastDay(start, 12),
            };
            _ledger.markAbsent(
              key,
              now,
              settled: now.difference(last) > _reportLag,
            );
          }
        },
        onError: (Object _) {
          if (identical(_inFlight[key], fetch)) _inFlight.remove(key);
        },
      ),
    );
    return fetch;
  }

  Future<Map<String, int>?> _fetchReport(
    String vendor,
    SalesFrequency frequency,
    String date,
  ) async {
    final response = await _http.get(
      Uri.https(_host, '/v1/salesReports', {
        'filter[frequency]': frequency.code,
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

/// One period's report: [label] is the month or year it counts toward.
typedef _Report = ({String label, DateTime last, Map<String, int> report});
