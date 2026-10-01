import 'package:store_console/store_console.dart';

/// How often a Summary Sales Report is cut, in Apple's words.
enum SalesFrequency {
  daily('DAILY'),
  monthly('MONTHLY'),
  yearly('YEARLY');

  const SalesFrequency(this.code);
  final String code;
}

/// The `filter[reportDate]` Apple takes for each [SalesFrequency]:
/// `2026-09-30`, `2026-09`, `2026`.
String salesReportDate(SalesFrequency frequency, DateTime day) {
  final year = day.year.toString().padLeft(4, '0');
  final month = day.month.toString().padLeft(2, '0');
  return switch (frequency) {
    SalesFrequency.yearly => year,
    SalesFrequency.monthly => '$year-$month',
    SalesFrequency.daily =>
      '$year-$month-${day.day.toString().padLeft(2, '0')}',
  };
}

/// Sales reports of finished periods already read, by vendor: a finished
/// day, month or year never changes, so each is fetched once. A period Apple
/// had no report for is asked about again after a while, unless it is long
/// past. Whoever holds it across refreshes keeps it with [toJson].
class AppleSalesLedger {
  AppleSalesLedger();

  factory AppleSalesLedger.fromJson(Map<String, Object?> json) {
    final ledger = AppleSalesLedger();
    final held = json['held'];
    if (held is Map) {
      for (final MapEntry(:key, :value) in held.entries) {
        if (key is! String || value is! Map) continue;
        ledger._held[key] = {
          for (final MapEntry(key: app, value: units) in value.entries)
            if (app is String && units is num) app: units.toInt(),
        };
      }
    }
    final absent = json['absent'];
    if (absent is Map) {
      for (final MapEntry(:key, :value) in absent.entries) {
        if (key is! String || value is! Map) continue;
        final at = DateTime.tryParse(value['at'] as String? ?? '');
        if (at == null) continue;
        ledger._absent[key] = (at: at, settled: value['settled'] == true);
      }
    }
    return ledger;
  }

  final _held = <String, Map<String, int>>{};
  final _absent = <String, ({DateTime at, bool settled})>{};

  /// A daily report is not kept past this: Apple keeps them about a year.
  static const Duration dailyKept = Duration(days: 400);

  static String key(String vendor, SalesFrequency frequency, String date) =>
      '$vendor|${frequency.code}|$date';

  /// First-time download units by Apple identifier, when read before.
  Map<String, int>? held(String key) => _held[key];

  /// Whether Apple said it had no report for [key] recently enough, or for
  /// good, that it is not asked again yet.
  bool absent(String key, DateTime now, Duration retry) {
    final seen = _absent[key];
    if (seen == null) return false;
    return seen.settled || now.difference(seen.at) < retry;
  }

  void keep(String key, Map<String, int> units) {
    _held[key] = Map.unmodifiable(units);
    _absent.remove(key);
  }

  /// [settled]: a period so long past a report will never appear for it.
  void markAbsent(String key, DateTime at, {bool settled = false}) =>
      _absent[key] = (at: at, settled: settled);

  /// Drops daily reports older than [dailyKept].
  void prune(DateTime now) {
    final oldest = now.subtract(dailyKept);
    bool stale(String key) {
      final parts = key.split('|');
      if (parts.length != 3 || parts[1] != SalesFrequency.daily.code) {
        return false;
      }
      final day = DateTime.tryParse(parts[2]);
      return day != null && day.isBefore(oldest);
    }

    _held.removeWhere((key, _) => stale(key));
    _absent.removeWhere((key, _) => stale(key));
  }

  void clear() {
    _held.clear();
    _absent.clear();
  }

  Map<String, Object?> toJson() => {
    'held': _held,
    'absent': {
      for (final MapEntry(:key, :value) in _absent.entries)
        key: {
          'at': value.at.toUtc().toIso8601String(),
          'settled': value.settled,
        },
    },
  };
}

/// One finished period's first-time downloads of one app.
typedef SalesPeriod = ({String label, DateTime last, int units});

/// The all-time count from every period read, in any order: [SalesPeriod.label]
/// of the oldest with a download is where it is counted from.
InstallTotal allTimeFromPeriods(List<SalesPeriod> periods) {
  if (periods.isEmpty) {
    throw const StoreException(
      StoreFailure.notSupported,
      'No sales reports yet.',
    );
  }
  final counted = [
    for (final period in periods)
      if (period.units != 0) period,
  ]..sort((a, b) => a.last.compareTo(b.last));
  if (counted.isEmpty) {
    throw const StoreException(
      StoreFailure.notSupported,
      'The sales reports have no first-time downloads of this app yet.',
    );
  }
  final sum = counted.fold<int>(0, (total, period) => total + period.units);
  final through = periods
      .map((period) => period.last)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  return InstallTotal(
    count: sum < 0 ? 0 : sum,
    measure: 'first-time downloads',
    source: InstallTotalSource.reports,
    since: counted.first.label,
    through: through,
  );
}
