import 'package:karmashala_store/database.dart';
import 'package:agent_cli/read.dart';

/// One visible turn, on its way into the index.
class ConversationTurn {
  const ConversationTurn({
    required this.ordinal,
    required this.role,
    required this.text,
  });

  /// The turn's position in the transcript as parsed, tool rows included. A
  /// hint, never a key: format drift shifts every ordinal after it.
  final int ordinal;

  /// `user` or `agent`. A `tool` row never reaches here — see
  /// `ConversationIndexer`.
  final String role;

  final String text;
}

/// What the index knows about one conversation, and when it knew it.
class ConversationIndexState {
  const ConversationIndexState({
    required this.sessionId,
    required this.cli,
    required this.filePath,
    required this.turns,
    required this.indexedAt,
    this.modifiedAt,
    this.size,
  });

  final String sessionId;
  final String cli;
  final String filePath;

  /// The transcript's mtime and length when last read. Null together for a file
  /// that could not be stat-ed, which only means the next read cannot skip.
  final DateTime? modifiedAt;
  final int? size;

  /// Visible turns written. `0` is a real answer: a conversation with nothing
  /// said in it yet.
  final int turns;

  final DateTime indexedAt;

  /// Whether a transcript at [modifiedAt]/[size] is the one already read.
  bool matches({DateTime? modifiedAt, int? size}) =>
      this.modifiedAt != null &&
      this.size != null &&
      modifiedAt != null &&
      size != null &&
      this.modifiedAt!.isAtSameMomentAs(modifiedAt) &&
      this.size == size;
}

/// One matching turn, with the conversation it was said in.
class ConversationHit {
  const ConversationHit({
    required this.sessionId,
    required this.cli,
    required this.ordinal,
    required this.role,
    required this.excerpt,
    this.indexedAt,
  });

  final String sessionId;
  final String cli;
  final int ordinal;
  final String role;

  /// The matched text, cut down to the words around the match by FTS5 itself.
  final String excerpt;

  /// When this conversation was last read off disk — the age of the reading,
  /// which the surface showing a hit has to be able to say (CLAUDE.md §19).
  final DateTime? indexedAt;
}

/// How many turns go into one `INSERT`. `AppDatabase.execute` prepares per
/// call; five columns a row caps this at 6 553 variables per statement.
const int kConversationInsertBatch = 128;

/// How many matching turns one search reads. Unranked: `ORDER BY rank` is one
/// clause away, and no weighting is worth defending on day one.
const int kConversationSearchLimit = 50;

/// Data-access for the conversation index. Keyed by the CLI's own conversation
/// id, not our row id: a conversation moves between tables, the index must not.
class ConversationIndexDao {
  ConversationIndexDao(this._db);

  final AppDatabase _db;

  /// SQL statements this DAO has issued. The cost claim, and what the tests
  /// assert — the same shape as `SessionAdoptionService.storeSweeps`.
  int statements = 0;

  /// What the index last read for [sessionId], or null if it never has.
  ConversationIndexState? stateFor(String sessionId) {
    statements++;
    final rows = _db.query(
      'SELECT * FROM conversation_index_state WHERE session_id = ?;',
      [sessionId],
    );
    return rows.isEmpty ? null : _stateFromRow(rows.first);
  }

  /// Replaces every indexed turn of [sessionId] with [turns]. One transaction:
  /// a half-written index cannot be told from a conversation that says less.
  void replaceTurns({
    required String sessionId,
    required String cli,
    required String filePath,
    required List<ConversationTurn> turns,
    required DateTime indexedAt,
    DateTime? modifiedAt,
    int? size,
  }) {
    _db.transaction(() {
      statements++;
      _db.execute('DELETE FROM conversation_turns WHERE session_id = ?;', [
        sessionId,
      ]);
      const batch = kConversationInsertBatch;
      for (var start = 0; start < turns.length; start += batch) {
        final end = (start + batch).clamp(0, turns.length);
        final chunk = turns.sublist(start, end);
        final values = List.filled(chunk.length, '(?, ?, ?, ?, ?)').join(', ');
        final params = <Object?>[];
        for (final turn in chunk) {
          params.addAll([sessionId, cli, turn.ordinal, turn.role, turn.text]);
        }
        statements++;
        _db.execute(
          'INSERT INTO conversation_turns '
          '(session_id, cli, ordinal, role, text) VALUES $values;',
          params,
        );
      }
      _writeState(
        sessionId: sessionId,
        cli: cli,
        filePath: filePath,
        turns: turns.length,
        indexedAt: indexedAt,
        modifiedAt: modifiedAt,
        size: size,
      );
    });
  }

  /// Records the watermark without replacing what is indexed. A parse that found
  /// no turns cannot be told from format drift, so the old rows are the answer.
  void keepTurns({
    required String sessionId,
    required String cli,
    required String filePath,
    required int turns,
    required DateTime indexedAt,
    DateTime? modifiedAt,
    int? size,
  }) => _writeState(
    sessionId: sessionId,
    cli: cli,
    filePath: filePath,
    turns: turns,
    indexedAt: indexedAt,
    modifiedAt: modifiedAt,
    size: size,
  );

  void _writeState({
    required String sessionId,
    required String cli,
    required String filePath,
    required int turns,
    required DateTime indexedAt,
    DateTime? modifiedAt,
    int? size,
  }) {
    statements++;
    _db.execute(
      'INSERT INTO conversation_index_state '
      '(session_id, cli, file_path, modified_at, size, turns, indexed_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id) DO UPDATE SET '
      'cli = excluded.cli, file_path = excluded.file_path, '
      'modified_at = excluded.modified_at, size = excluded.size, '
      'turns = excluded.turns, indexed_at = excluded.indexed_at;',
      [
        sessionId,
        cli,
        filePath,
        modifiedAt == null ? null : isoFromDate(modifiedAt),
        size,
        turns,
        isoFromDate(indexedAt),
      ],
    );
  }

  /// The turns matching [query], capped at [limit]. Never throws on user input:
  /// [conversationMatchExpression] quotes it, so nothing reaches FTS5 as syntax.
  List<ConversationHit> search(
    String query, {
    int limit = kConversationSearchLimit,
  }) {
    final match = conversationMatchExpression(query);
    if (match == null) return const [];
    statements++;
    // No `ORDER BY`: unranked, which is FTS5's rowid order. See
    // [kConversationSearchLimit] for why that is the day-one target.
    final rows = _db.query(
      'SELECT t.session_id AS session_id, t.cli AS cli, '
      't.ordinal AS ordinal, t.role AS role, '
      "snippet(conversation_turns_fts, 0, '', '', '…', 14) AS excerpt, "
      'state.indexed_at AS indexed_at '
      'FROM conversation_turns_fts '
      'JOIN conversation_turns t ON t.id = conversation_turns_fts.rowid '
      'LEFT JOIN conversation_index_state state '
      'ON state.session_id = t.session_id '
      'WHERE conversation_turns_fts MATCH ? LIMIT ?;',
      [match, limit],
    );
    return [
      for (final row in rows)
        ConversationHit(
          sessionId: row['session_id'] as String,
          cli: row['cli'] as String,
          ordinal: row['ordinal'] as int,
          role: row['role'] as String,
          excerpt: (row['excerpt'] as String?) ?? '',
          indexedAt: row['indexed_at'] == null
              ? null
              : dateFromIso(row['indexed_at']),
        ),
    ];
  }

  /// How many turns are indexed for [sessionId]. Diagnostics and tests.
  int turnCountFor(String sessionId) {
    statements++;
    final rows = _db.query(
      'SELECT COUNT(*) AS n FROM conversation_turns WHERE session_id = ?;',
      [sessionId],
    );
    return rows.first['n'] as int;
  }

  /// Every conversation the index holds a watermark for.
  Set<String> indexedConversationIds() {
    statements++;
    return {
      for (final row in _db.query(
        'SELECT session_id FROM conversation_index_state;',
      ))
        row['session_id'] as String,
    };
  }

  /// Every conversation `imported_sessions` records a transcript path for. Read
  /// without the supersession filter: a hidden record still holds the only path.
  List<({String sessionId, String cli, String filePath})>
  recordedTranscripts() {
    statements++;
    return [
      for (final row in _db.query(
        'SELECT external_id, source, file_path FROM imported_sessions;',
      ))
        (
          sessionId: row['external_id'] as String,
          cli: row['source'] as String,
          filePath: row['file_path'] as String,
        ),
    ];
  }

  /// Every conversation a live session row names, with the agent running it.
  /// These have no path on file: a launched session was never imported.
  List<({String sessionId, String cli})> liveConversations() {
    statements++;
    return [
      for (final row in _db.query(
        'SELECT s.external_session_id AS session_id, '
        'a.agent_kind AS cli FROM sessions s '
        'JOIN agent_installations a ON a.id = s.agent_installation_id '
        "WHERE s.external_session_id IS NOT NULL "
        "AND s.external_session_id <> '';",
      ))
        (sessionId: row['session_id'] as String, cli: row['cli'] as String),
    ];
  }

  ConversationIndexState _stateFromRow(Map<String, Object?> row) =>
      ConversationIndexState(
        sessionId: row['session_id'] as String,
        cli: row['cli'] as String,
        filePath: row['file_path'] as String,
        modifiedAt: row['modified_at'] == null
            ? null
            : dateFromIso(row['modified_at']),
        size: row['size'] as int?,
        turns: row['turns'] as int,
        indexedAt: dateFromIso(row['indexed_at']),
      );
}
