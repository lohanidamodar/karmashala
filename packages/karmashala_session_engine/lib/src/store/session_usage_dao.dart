import 'dart:convert';

import 'package:karmashala_store/database.dart';

/// One turn's usage as the agent last reported it before the turn ended:
/// context tokens in use of the window's size, and the cumulative cost when
/// the agent gives one.
class SessionUsageTurn {
  const SessionUsageTurn({
    required this.contextUsed,
    required this.contextSize,
    this.costAmount,
    this.costCurrency,
  });

  final int contextUsed;
  final int contextSize;
  final double? costAmount;
  final String? costCurrency;

  Map<String, Object?> toJson() => {
    'used': contextUsed,
    'size': contextSize,
    'cost': ?costAmount,
    'currency': ?costCurrency,
  };

  static SessionUsageTurn? fromJson(Object? json) {
    if (json is! Map) return null;
    final used = json['used'], size = json['size'];
    if (used is! int || size is! int) return null;
    final cost = json['cost'];
    return SessionUsageTurn(
      contextUsed: used,
      contextSize: size,
      costAmount: cost is num ? cost.toDouble() : null,
      costCurrency: json['currency'] as String?,
    );
  }
}

/// One row of `session_usage`: what an ACP session's agent said of its own
/// usage. Every count is nullable, and null is "not reported" — never zero.
class SessionUsage {
  const SessionUsage({
    required this.sessionId,
    required this.updatedAt,
    this.contextUsed,
    this.contextSize,
    this.costAmount,
    this.costCurrency,
    this.turns = const [],
  });

  final String sessionId;

  /// The latest report, which can be newer than the last turn's.
  final int? contextUsed;
  final int? contextSize;
  final double? costAmount;
  final String? costCurrency;

  /// One entry per turn that ended with a report, oldest first.
  final List<SessionUsageTurn> turns;
  final DateTime updatedAt;
}

/// Data-access for `session_usage`: the latest report is replaced on each
/// `usage_update`, and the turn series grows by one as each turn ends.
class SessionUsageDao {
  SessionUsageDao(this._db);

  final AppDatabase _db;

  SessionUsage? getBySession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM session_usage WHERE session_id = ?;',
      [sessionId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The latest report for [sessionId]; the turn series is kept.
  SessionUsage recordLatest(
    String sessionId, {
    required int contextUsed,
    required int contextSize,
    double? costAmount,
    String? costCurrency,
    required DateTime at,
  }) => _db.transaction(() {
    final current = getBySession(sessionId);
    return _write(
      SessionUsage(
        sessionId: sessionId,
        contextUsed: contextUsed,
        contextSize: contextSize,
        costAmount: costAmount ?? current?.costAmount,
        costCurrency: costCurrency ?? current?.costCurrency,
        turns: current?.turns ?? const [],
        updatedAt: at,
      ),
    );
  });

  /// A turn ended with [turn] as its last report: appended to the series,
  /// and the latest report moves to it.
  SessionUsage recordTurn(
    String sessionId,
    SessionUsageTurn turn, {
    required DateTime at,
  }) => _db.transaction(() {
    final current = getBySession(sessionId);
    return _write(
      SessionUsage(
        sessionId: sessionId,
        contextUsed: turn.contextUsed,
        contextSize: turn.contextSize,
        costAmount: turn.costAmount ?? current?.costAmount,
        costCurrency: turn.costCurrency ?? current?.costCurrency,
        turns: [...?current?.turns, turn],
        updatedAt: at,
      ),
    );
  });

  void deleteForSession(String sessionId) {
    _db.execute('DELETE FROM session_usage WHERE session_id = ?;', [sessionId]);
  }

  SessionUsage _write(SessionUsage usage) {
    _db.execute(
      'INSERT INTO session_usage (session_id, context_used, context_size, '
      'cost_amount, cost_currency, turns_json, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id) DO UPDATE SET '
      'context_used = excluded.context_used, '
      'context_size = excluded.context_size, '
      'cost_amount = excluded.cost_amount, '
      'cost_currency = excluded.cost_currency, '
      'turns_json = excluded.turns_json, '
      'updated_at = excluded.updated_at;',
      [
        usage.sessionId,
        usage.contextUsed,
        usage.contextSize,
        usage.costAmount,
        usage.costCurrency,
        jsonEncode([for (final turn in usage.turns) turn.toJson()]),
        isoFromDate(usage.updatedAt),
      ],
    );
    return usage;
  }

  SessionUsage _fromRow(Map<String, Object?> row) {
    final cost = row['cost_amount'];
    Object? decoded;
    try {
      decoded = jsonDecode(row['turns_json'] as String? ?? '[]');
    } on FormatException {
      decoded = null;
    }
    return SessionUsage(
      sessionId: row['session_id']! as String,
      contextUsed: row['context_used'] as int?,
      contextSize: row['context_size'] as int?,
      costAmount: cost is num ? cost.toDouble() : null,
      costCurrency: row['cost_currency'] as String?,
      turns: [
        if (decoded is List)
          for (final item in decoded) ?SessionUsageTurn.fromJson(item),
      ],
      updatedAt: dateFromIso(row['updated_at']),
    );
  }
}
