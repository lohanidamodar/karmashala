import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:agent_cli/read.dart';

/// One visible turn, on its way into the index.
class ConversationTurn {
  const ConversationTurn({
    required this.ordinal,
    required this.role,
    required this.text,
  });

  /// The turn's position in the transcript **as parsed**, tool rows included.
  ///
  /// A hint for a future jump, never a key: `readCliTranscript` is best-effort,
  /// so a transcript whose format has drifted parses to fewer rows and every
  /// ordinal after the drift shifts. Nothing may resolve a turn by it.
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

  /// The transcript's mtime and length when it was last read. Null together for
  /// a read whose file could not be stat-ed — which is a real state, not a
  /// missing one, and simply means the next trigger cannot skip.
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

  /// When this conversation was last read off disk, or null for a row whose
  /// watermark has since been deleted. **The age of the reading** — a hit is
  /// only ever as current as the last trigger that indexed its conversation,
  /// and the surface showing it has to be able to say so (CLAUDE.md §19).
  final DateTime? indexedAt;
}

/// How many turns go into one `INSERT`.
///
/// Statement count is the cost being managed here: `AppDatabase.execute`
/// prepares and finalises per call, so a 2 000-turn transcript is 2 000
/// prepares at one row each and 16 at this width. Not larger, because
/// `SQLITE_MAX_VARIABLE_NUMBER` is 32 766 in this build and five columns a row
/// puts the ceiling at 6 553.
const int kConversationInsertBatch = 128;

/// How many matching turns one search reads.
///
/// t3.codes' day-one number, taken deliberately rather than beaten: their
/// version is forty lines of `LIKE` because they own the message rows, and the
/// honest comparison is that we had to build the index first. Unranked for the
/// same reason — `ORDER BY rank` is one clause away and nobody should have to
/// defend a weighting on day one.
const int kConversationSearchLimit = 50;

/// Data-access for the conversation index. Hand-written SQL, no codegen.
///
/// **Keyed by the CLI's own conversation id**, not our session row id, because
/// a conversation moves between `sessions` and `imported_sessions` over its
/// life and the index must not move with it.
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

  /// Replaces every indexed turn of [sessionId] with [turns], and dates it.
  ///
  /// **One transaction, so a failure leaves the previous rows in place.** A
  /// half-written index is the one outcome that would be worse than a stale
  /// one: it cannot be told from a conversation that genuinely says less.
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

  /// Records that [sessionId]'s transcript was read at this watermark **without
  /// replacing what is indexed**.
  ///
  /// The degraded case: a parse that produced no visible turns is
  /// indistinguishable from a transcript whose format we no longer understand,
  /// and the rows already there are the best answer we have. Advancing the
  /// watermark anyway is what stops the next trigger re-parsing the same file
  /// to learn the same nothing.
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

  /// The turns matching [query], oldest-indexed first, capped at [limit].
  ///
  /// Returns empty for a query too short or too punctuated to search for, and
  /// **never throws on what the user typed**: the expression is built from
  /// quoted string literals by [conversationMatchExpression], so no input
  /// reaches FTS5 as an operator.
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

  /// Every conversation `imported_sessions` records a transcript path for.
  ///
  /// Read **without** the supersession filter every other read of that table
  /// carries. A record a native session row has taken over is hidden from lists
  /// because the live row is the better representation — but it is still the
  /// only place the path to that conversation's transcript is written down, and
  /// this index is keyed by the conversation rather than by either row.
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
  ///
  /// These have no path on file — a launched session was never imported —
  /// so the backfill has to find them in a store, and the triggers hand them
  /// to `ConversationIndexer.want` without one.
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
        (
          sessionId: row['session_id'] as String,
          cli: row['cli'] as String,
        ),
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
