import 'package:store_console/store_console.dart';

import 'play_reports_bucket.dart';
import 'report_csv.dart';

/// What one monthly installs overview says, reduced to what an all-time
/// count needs. A sum is null when the file has no such column.
class MonthInstalls {
  const MonthInstalls({
    this.userInstalls,
    this.deviceInstalls,
    this.totalUsers,
    this.totalUsersDay,
    this.lastDay,
  });

  /// The month's `Daily User Installs`, summed.
  final int? userInstalls;

  /// The month's `Daily Device Installs`, summed.
  final int? deviceInstalls;

  /// The newest `Total User Installs`: Play's own lifetime count of users.
  final int? totalUsers;
  final DateTime? totalUsersDay;

  /// The newest day with a row.
  final DateTime? lastDay;

  Map<String, Object?> toJson() => {
    'userInstalls': userInstalls,
    'deviceInstalls': deviceInstalls,
    'totalUsers': totalUsers,
    'totalUsersDay': totalUsersDay?.toUtc().toIso8601String(),
    'lastDay': lastDay?.toUtc().toIso8601String(),
  };

  factory MonthInstalls.fromJson(Map<String, Object?> json) => MonthInstalls(
    userInstalls: (json['userInstalls'] as num?)?.toInt(),
    deviceInstalls: (json['deviceInstalls'] as num?)?.toInt(),
    totalUsers: (json['totalUsers'] as num?)?.toInt(),
    totalUsersDay: _parsed(json['totalUsersDay']),
    lastDay: _parsed(json['lastDay']),
  );
}

DateTime? _parsed(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// One monthly installs overview, summarised.
MonthInstalls summariseInstalls(ReportTable table) {
  final date = table.column(const ['Date']);
  if (date == null) {
    throw const StoreException(
      StoreFailure.shape,
      'The installs report has no Date column.',
    );
  }
  final user = table.column(const ['Daily User Installs']);
  final device = table.column(const ['Daily Device Installs']);
  final total = table.column(const ['Total User Installs']);
  int? userSum = user == null ? null : 0;
  int? deviceSum = device == null ? null : 0;
  int? totalUsers;
  DateTime? totalUsersDay;
  DateTime? lastDay;
  int? number(List<String> row, int? at) =>
      at == null ? null : int.tryParse(ReportTable.cell(row, at) ?? '');
  for (final row in table.rows) {
    final day = reportDay(ReportTable.cell(row, date));
    if (day == null) continue;
    if (lastDay == null || day.isAfter(lastDay)) lastDay = day;
    if (number(row, user) case final count?) userSum = userSum! + count;
    if (number(row, device) case final count?) deviceSum = deviceSum! + count;
    if (number(row, total) case final count?
        when totalUsersDay == null || !day.isBefore(totalUsersDay)) {
      totalUsers = count;
      totalUsersDay = day;
    }
  }
  return MonthInstalls(
    userInstalls: userSum,
    deviceInstalls: deviceSum,
    totalUsers: totalUsers,
    totalUsersDay: totalUsersDay,
    lastDay: lastDay,
  );
}

/// The month an installs overview of [packageName] covers, from its object
/// name; null for any other file, another package's whose name only starts
/// like this one's included.
DateTime? installsMonthOf(String object, String packageName) {
  final match = RegExp(
    '^stats/installs/installs_${RegExp.escape(packageName)}_'
    r'(\d{4})(\d{2})_overview\.csv$',
  ).firstMatch(object);
  if (match == null) return null;
  final month = int.parse(match.group(2)!);
  if (month < 1 || month > 12) return null;
  return DateTime.utc(int.parse(match.group(1)!), month);
}

String installsPrefix(String packageName) =>
    'stats/installs/installs_${packageName}_';

/// The all-time count from every month's summary, oldest month first: Play's
/// own `Total User Installs` from the newest month when it gives one, else
/// the daily user installs of every month added up — device installs for a
/// month that has no user column.
InstallTotal allTimeFromMonths(List<(DateTime, MonthInstalls)> months) {
  if (months.isEmpty) {
    throw const StoreException(
      StoreFailure.notSupported,
      'Google Play has not written an installs report for this app yet.',
    );
  }
  final (_, newest) = months.last;
  if (newest.totalUsers case final total? when total > 0) {
    return InstallTotal(
      count: total,
      measure: 'user installs',
      source: InstallTotalSource.reports,
      through: newest.totalUsersDay,
    );
  }
  var sum = 0;
  var users = 0;
  var devices = 0;
  DateTime? first;
  DateTime? through;
  for (final (month, summary) in months) {
    final count = summary.userInstalls ?? summary.deviceInstalls;
    if (count == null) continue;
    summary.userInstalls != null ? users++ : devices++;
    sum += count;
    first ??= month;
    if (summary.lastDay case final day?
        when through == null || day.isAfter(through)) {
      through = day;
    }
  }
  if (first == null) {
    throw const StoreException(
      StoreFailure.shape,
      'The installs reports have no daily installs column.',
    );
  }
  return InstallTotal(
    count: sum < 0 ? 0 : sum,
    measure: devices == 0
        ? 'user installs'
        : users == 0
        ? 'device installs'
        : 'installs',
    source: InstallTotalSource.reports,
    since:
        '${first.year.toString().padLeft(4, '0')}-'
        '${first.month.toString().padLeft(2, '0')}',
    through: through,
  );
}

/// Monthly summaries already read, by bucket and file, each with the
/// generation it was read at: a month is read again only when its file
/// changes. Whoever holds it across refreshes keeps it with [toJson].
class PlayInstallMonths {
  PlayInstallMonths();

  factory PlayInstallMonths.fromJson(Map<String, Object?> json) {
    final months = PlayInstallMonths();
    for (final MapEntry(:key, :value) in json.entries) {
      if (value is! Map) continue;
      final held = value.cast<String, Object?>();
      final generation = held['generation'];
      final summary = held['summary'];
      if (generation is! String || summary is! Map) continue;
      months._held[key] = (
        generation: generation,
        summary: MonthInstalls.fromJson(summary.cast<String, Object?>()),
      );
    }
    return months;
  }

  final _held = <String, ({String generation, MonthInstalls summary})>{};

  bool get isEmpty => _held.isEmpty;

  static String _key(String bucket, String object) => '$bucket/$object';

  /// What [object] said at [generation], when read at it.
  MonthInstalls? at(String bucket, String object, String generation) {
    final held = _held[_key(bucket, object)];
    return held != null && held.generation == generation && generation != ''
        ? held.summary
        : null;
  }

  void keep(
    String bucket,
    String object,
    String generation,
    MonthInstalls summary,
  ) => _held[_key(bucket, object)] = (generation: generation, summary: summary);

  /// Drops every file of [bucket] whose name starts with [prefix] that is
  /// not in [present]: deleted months, not to be counted again.
  void keepOnly(String bucket, String prefix, Set<String> present) =>
      _held.removeWhere((key, _) {
        final start = _key(bucket, prefix);
        return key.startsWith(start) &&
            !present.contains(key.substring(bucket.length + 1));
      });

  void clear() => _held.clear();

  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, :value) in _held.entries)
      key: {'generation': value.generation, 'summary': value.summary.toJson()},
  };
}

/// How many monthly files are read at once on a first count.
const int _parallelReads = 6;

/// Every install [packageName] has had, from the bucket's monthly installs
/// overviews: the bucket is listed once, and only a month not held in
/// [months] at its current generation is read.
Future<InstallTotal> readAllTimeInstalls(
  PlayReportsBucket bucket,
  String packageName,
  PlayInstallMonths months,
) async {
  final prefix = installsPrefix(packageName);
  final files = <(DateTime, BucketObject)>[
    for (final object in await bucket.list(prefix))
      if (installsMonthOf(object.name, packageName) case final month?)
        (month, object),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  months.keepOnly(bucket.bucket, prefix, {
    for (final (_, object) in files) object.name,
  });

  Future<MonthInstalls?> summary(BucketObject object) async {
    final held = months.at(bucket.bucket, object.name, object.generation);
    if (held != null) return held;
    final table = await bucket.read(object.name);
    if (table == null) return null;
    final read = summariseInstalls(table);
    months.keep(bucket.bucket, object.name, object.generation, read);
    return read;
  }

  if (files.isEmpty) return allTimeFromMonths(const []);
  // The newest month alone answers when Play gives its own lifetime count.
  final (newestMonth, newestObject) = files.last;
  final newest = await summary(newestObject);
  if (newest != null && (newest.totalUsers ?? 0) > 0) {
    return allTimeFromMonths([(newestMonth, newest)]);
  }
  final read = <(DateTime, MonthInstalls)>[];
  for (var start = 0; start < files.length; start += _parallelReads) {
    final batch = files.skip(start).take(_parallelReads).toList();
    final summaries = await Future.wait([
      for (final (_, object) in batch) summary(object),
    ]);
    for (final (i, found) in summaries.indexed) {
      if (found != null) read.add((batch[i].$1, found));
    }
  }
  return allTimeFromMonths(read);
}
