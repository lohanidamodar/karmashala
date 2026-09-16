import 'package:karmashala_store/database.dart';

import '../domain/usage_sample.dart';

/// Data-access for the usage history (schema v51).
class UsageSampleDao {
  UsageSampleDao(this._db);

  final AppDatabase _db;

  /// Stores [sample]; a second sample for the same window and second replaces
  /// the first.
  void insert(UsageSample sample) {
    _db.execute(
      'INSERT OR REPLACE INTO usage_samples '
      '(account_key, window_label, span_seconds, percent, resets_at, '
      'recorded_at) VALUES (?, ?, ?, ?, ?, ?);',
      [
        sample.accountKey,
        sample.windowLabel,
        sample.span?.inSeconds,
        sample.percent,
        sample.resetsAt == null ? null : isoFromDate(sample.resetsAt!),
        isoFromDate(sample.recordedAt),
      ],
    );
  }

  /// The newest sample of one window, or null.
  UsageSample? latest(String accountKey, String windowLabel) {
    final rows = _db.query(
      'SELECT * FROM usage_samples WHERE account_key = ? AND window_label = ? '
      'ORDER BY recorded_at DESC LIMIT 1;',
      [accountKey, windowLabel],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every sample of [accountKey] recorded at or after [since], oldest first.
  List<UsageSample> since(String accountKey, DateTime since) => [
    for (final row in _db.query(
      'SELECT * FROM usage_samples WHERE account_key = ? AND recorded_at >= ? '
      'ORDER BY recorded_at ASC;',
      [accountKey, isoFromDate(since)],
    ))
      _fromRow(row),
  ];

  int count() =>
      _db.query('SELECT COUNT(*) AS n FROM usage_samples;').first['n']! as int;

  /// Forgets samples older than [keep], and thins those older than
  /// [fullResolution] to the highest reading per window per hour — the peak
  /// is what a limit is about.
  void prune({
    required DateTime now,
    required Duration keep,
    required Duration fullResolution,
  }) {
    _db.transaction(() {
      _db.execute('DELETE FROM usage_samples WHERE recorded_at < ?;', [
        isoFromDate(now.subtract(keep)),
      ]);
      final cutoff = isoFromDate(now.subtract(fullResolution));
      // SQLite takes a bare column beside MAX() from the row holding the max.
      _db.execute(
        'DELETE FROM usage_samples WHERE recorded_at < ? AND rowid NOT IN ('
        'SELECT keep_id FROM (SELECT rowid AS keep_id, MAX(percent) '
        'FROM usage_samples WHERE recorded_at < ? '
        'GROUP BY account_key, window_label, substr(recorded_at, 1, 13)));',
        [cutoff, cutoff],
      );
    });
  }

  UsageSample _fromRow(Map<String, Object?> row) {
    final span = row['span_seconds'] as int?;
    final resets = row['resets_at'];
    return UsageSample(
      accountKey: row['account_key']! as String,
      windowLabel: row['window_label']! as String,
      span: span == null ? null : Duration(seconds: span),
      percent: (row['percent']! as num).toDouble(),
      resetsAt: resets == null ? null : dateFromIso(resets),
      recordedAt: dateFromIso(row['recorded_at']),
    );
  }
}
