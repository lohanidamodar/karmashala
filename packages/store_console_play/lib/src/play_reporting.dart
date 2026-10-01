import 'dart:convert';

import 'package:http/http.dart' as http;

import 'play_errors.dart';

const String _root = 'https://playdeveloperreporting.googleapis.com/v1beta1';

/// The only timezone the API aggregates days in.
const String _dailyZone = 'America/Los_Angeles';

const int vitalsDays = 28;

/// A metric set and the user-perceived rate it reports.
enum VitalsMetric {
  crash('crashRateMetricSet', 'userPerceivedCrashRate'),
  anr('anrRateMetricSet', 'userPerceivedAnrRate');

  const VitalsMetric(this.metricSet, this.rate);

  final String metricSet;
  final String rate;

  String get rate28d => '${rate}28dUserWeighted';
}

typedef ReportingApp = ({String packageName, String? displayName});

/// The apps on one page of `apps:search`.
List<ReportingApp> parseReportingApps(Map<String, Object?> json) => [
  for (final app in _maps(json['apps']))
    if (app['packageName'] case final String packageName
        when packageName.isNotEmpty)
      (
        packageName: packageName,
        displayName: switch (app['displayName']) {
          final String name when name.trim().isNotEmpty => name.trim(),
          _ => null,
        },
      ),
];

/// The day after the last one a metric set has DAILY data for, or null when
/// it does not say.
DateTime? parseDailyFreshness(Map<String, Object?> json) {
  final info = json['freshnessInfo'];
  if (info is! Map) return null;
  for (final freshness in _maps(info['freshnesses'])) {
    if (freshness['aggregationPeriod'] == 'DAILY') {
      return _day(freshness['latestEndTime']);
    }
  }
  return null;
}

/// The query for [metric] over the days from [start] up to, not including,
/// [end].
Map<String, Object?> vitalsQuery(
  VitalsMetric metric, {
  required DateTime start,
  required DateTime end,
}) => {
  'timelineSpec': {
    'aggregationPeriod': 'DAILY',
    'startTime': _dayJson(start),
    'endTime': _dayJson(end),
  },
  'metrics': [metric.rate28d, metric.rate, 'distinctUsers'],
  'pageSize': 100,
};

/// The rate over the queried window as a fraction, or null when the API
/// returned no usable row: the newest 28-day figure, else the daily rates
/// weighted by their users.
double? parseVitalsRate(Map<String, Object?> json, VitalsMetric metric) {
  final rows = [
    for (final row in _maps(json['rows']))
      (day: _day(row['startTime']), metrics: _metrics(row['metrics'])),
  ];
  if (rows.isEmpty) return null;
  rows.sort((a, b) => (b.day ?? _epoch).compareTo(a.day ?? _epoch));
  for (final row in rows) {
    final rolling = row.metrics[metric.rate28d];
    if (rolling != null) return rolling;
  }
  var weighted = 0.0;
  var users = 0.0;
  var plain = 0.0;
  var count = 0;
  for (final row in rows) {
    final rate = row.metrics[metric.rate];
    if (rate == null) continue;
    final weight = row.metrics['distinctUsers'] ?? 0;
    weighted += rate * weight;
    users += weight;
    plain += rate;
    count++;
  }
  if (count == 0) return null;
  return users > 0 ? weighted / users : plain / count;
}

final DateTime _epoch = DateTime.utc(1970);

Map<String, double> _metrics(Object? metrics) {
  final values = <String, double>{};
  void put(Object? name, Object? value) {
    final decimal = value is Map ? value['decimalValue'] : null;
    final text = decimal is Map ? decimal['value'] : decimal;
    final number = text is num ? text.toDouble() : double.tryParse('$text');
    if (name is String && number != null) values[name] = number;
  }

  if (metrics is List) {
    for (final metric in metrics) {
      if (metric is Map) put(metric['metric'], metric);
    }
  } else if (metrics is Map) {
    metrics.forEach(put);
  }
  return values;
}

DateTime? _day(Object? json) {
  if (json is! Map) return null;
  final year = json['year'];
  final month = json['month'];
  final day = json['day'];
  if (year is! int || month is! int || day is! int) return null;
  return DateTime.utc(year, month, day);
}

Map<String, Object?> _dayJson(DateTime day) => {
  'year': day.year,
  'month': day.month,
  'day': day.day,
  'timeZone': {'id': _dailyZone},
};

Iterable<Map<Object?, Object?>> _maps(Object? list) =>
    list is List ? list.whereType<Map<Object?, Object?>>() : const [];

/// Play Developer Reporting, which `googleapis` has no client for.
class PlayReporting {
  PlayReporting(this._client);

  /// An authorised client.
  final http.Client _client;

  Future<List<ReportingApp>> searchApps() async {
    final apps = <ReportingApp>[];
    String? pageToken;
    // Bounded, so a token that never runs out cannot loop for ever.
    for (var page = 0; page < 20; page++) {
      final json = await _read(
        _client.get(
          Uri.parse('$_root/apps:search').replace(
            queryParameters: {'pageSize': '1000', 'pageToken': ?pageToken},
          ),
        ),
      );
      apps.addAll(parseReportingApps(json));
      final next = json['nextPageToken'];
      if (next is! String || next.isEmpty) break;
      pageToken = next;
    }
    return apps;
  }

  Future<DateTime?> dailyFreshness(String packageName, VitalsMetric metric) =>
      _read(
        _client.get(_metricSet(packageName, metric)),
      ).then(parseDailyFreshness);

  Future<double?> rate(
    String packageName,
    VitalsMetric metric, {
    required DateTime start,
    required DateTime end,
  }) async {
    final json = await _read(
      _client.post(
        Uri.parse('${_metricSet(packageName, metric)}:query'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(vitalsQuery(metric, start: start, end: end)),
      ),
    );
    return parseVitalsRate(json, metric);
  }

  Uri _metricSet(String packageName, VitalsMetric metric) => Uri.parse(
    '$_root/apps/${Uri.encodeComponent(packageName)}/${metric.metricSet}',
  );

  Future<Map<String, Object?>> _read(Future<http.Response> call) async {
    final response = await call;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Only the error's structured fields are read from the body.
      throw playStatusFailure(
        response.statusCode,
        area: PlayArea.reporting,
        facts: PlayErrorFacts.fromBody(_decoded(response)),
      );
    }
    final body = _decoded(response);
    if (body is! Map) {
      throw playStatusFailure(null, area: PlayArea.reporting);
    }
    return body.cast<String, Object?>();
  }

  /// The body as JSON, or null when it is not JSON.
  static Object? _decoded(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      return null;
    }
  }
}
