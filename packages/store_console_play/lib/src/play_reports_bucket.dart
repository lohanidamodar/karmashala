import 'dart:typed_data';

// Prefixed: the library has an `Object` of its own. Its successor,
// google_cloud_storage, is not a dependency of this workspace.
// ignore: deprecated_member_use
import 'package:googleapis/storage/v1.dart' as storage;
import 'package:store_console/store_console.dart';

import 'report_csv.dart';

/// The bucket's bare name from whatever was pasted: a `gs://` address, a
/// name, or the bare id. Null when nothing usable was typed.
String? normaliseBucket(String? typed) {
  var name = (typed ?? '').trim();
  if (name.toLowerCase().startsWith('gs://')) name = name.substring(5);
  final slash = name.indexOf('/');
  if (slash >= 0) name = name.substring(0, slash);
  name = name.trim();
  if (name.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(name)) return 'pubsite_prod_rev_$name';
  return name;
}

String _month(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}'
    '${month.month.toString().padLeft(2, '0')}';

String ratingsObject(String packageName, DateTime month) =>
    'stats/ratings/ratings_${packageName}_${_month(month)}_overview.csv';

String installsObject(String packageName, DateTime month) =>
    'stats/installs/installs_${packageName}_${_month(month)}_overview.csv';

/// The first day of the month before [month]'s.
DateTime previousMonth(DateTime month) =>
    DateTime.utc(month.year, month.month - 1);

/// The newest `Total Average Rating` the report has a number for, or null.
double? latestAverageRating(ReportTable table) {
  final date = table.column(const ['Date']);
  final rating = table.column(const ['Total Average Rating']);
  if (date == null || rating == null) {
    throw const StoreException(
      StoreFailure.shape,
      'The ratings report has no Total Average Rating column.',
    );
  }
  DateTime? newest;
  double? average;
  for (final row in table.rows) {
    final day = _day(ReportTable.cell(row, date));
    final value = double.tryParse(ReportTable.cell(row, rating) ?? '');
    if (day == null || value == null) continue;
    if (newest == null || !day.isBefore(newest)) {
      newest = day;
      average = value;
    }
  }
  return average;
}

/// Installs per day from [from] to [to] inclusive, as the report counts them.
Map<DateTime, int> dailyInstalls(
  ReportTable table, {
  required DateTime from,
  required DateTime to,
}) {
  final date = table.column(const ['Date']);
  final installs = table.column(const [
    'Daily User Installs',
    'Daily Device Installs',
  ]);
  if (date == null || installs == null) {
    throw const StoreException(
      StoreFailure.shape,
      'The installs report has no daily installs column.',
    );
  }
  final days = <DateTime, int>{};
  for (final row in table.rows) {
    final day = _day(ReportTable.cell(row, date));
    final count = int.tryParse(ReportTable.cell(row, installs) ?? '');
    if (day == null || count == null) continue;
    if (day.isBefore(from) || day.isAfter(to)) continue;
    days[day] = count;
  }
  return days;
}

DateTime? _day(String? text) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(text ?? '');
  if (match == null) return null;
  return DateTime.utc(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

/// Reads report files out of the Play Console bucket.
class PlayReportsBucket {
  PlayReportsBucket(this._storage, this.bucket);

  final storage.StorageApi _storage;
  final String bucket;

  /// The report at [object], or null when the bucket has no such file.
  Future<ReportTable?> read(String object) async {
    final Object media;
    try {
      media = await _storage.objects.get(
        bucket,
        object,
        downloadOptions: storage.DownloadOptions.fullMedia,
      );
    } on storage.DetailedApiRequestError catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
    if (media is! storage.Media) {
      throw const StoreException(
        StoreFailure.shape,
        'The reports bucket answered without the file.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await media.stream.forEach(bytes.add);
    return ReportTable.decode(bytes.takeBytes());
  }
}
