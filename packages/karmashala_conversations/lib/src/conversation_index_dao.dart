import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/read.dart';

import 'conversation_values.dart';

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
    this.resumePoint,
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

  /// Where the last read stopped, so the next reads only what was appended.
  /// Null before v56 and after a read that could not reach a record boundary.
  final TranscriptResumePoint? resumePoint;

  /// Whether a transcript at [modifiedAt]/[size] is the one already read.
  bool matches({DateTime? modifiedAt, int? size}) =>
      this.modifiedAt != null &&
      this.size != null &&
      modifiedAt != null &&
      size != null &&
      this.modifiedAt!.isAtSameMomentAs(modifiedAt) &&
      this.size == size;
}

/// One conversation's place in a ranked search, before its excerpt is cut.
typedef RankedConversation = ({
  String sessionId,
  String cli,
  int bestTurnId,
  double score,
  int matches,
  DateTime? indexedAt,
});

/// How many turns go into one `INSERT`. `AppDatabase.execute` prepares per
/// call; six columns a row caps this at 5 461 variables per statement.
const int kConversationInsertBatch = 128;

/// Turns one transaction writes of a large conversation's first reading; the
/// indexer hands the event loop back between slices.
const int kConversationWriteSlice = 128;

/// How many matching turns one [ConversationIndexDao.search] reads.
const int kConversationSearchLimit = 50;

/// The most matching turns one ranking scores, newest first. BM25 is computed
/// per match, so a word said in every turn would otherwise cost a scan of the
/// whole index on every keystroke; past this a query ranks its newest matches.
const int kConversationRankCandidates = 2000;

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

  /// Bumped by every write that changes what a search can find.
  int get generation {
    statements++;
    final value = _db.readMetadata(kConversationIndexGenerationKey);
    return value == null ? 0 : int.tryParse(value) ?? 0;
  }

  void _bumpGeneration() {
    statements++;
    _db.execute(
      'INSERT INTO app_metadata (key, value, updated_at) '
      "VALUES (?, '1', ?) ON CONFLICT(key) DO UPDATE SET "
      'value = CAST(CAST(value AS INTEGER) + 1 AS TEXT), '
      'updated_at = excluded.updated_at;',
      [kConversationIndexGenerationKey, isoFromDate(DateTime.now())],
    );
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
    TranscriptResumePoint? resumePoint,
  }) {
    _db.transaction(() {
      statements++;
      _db.execute('DELETE FROM conversation_turns WHERE session_id = ?;', [
        sessionId,
      ]);
      _insert(sessionId, cli, turns);
      _writeState(
        sessionId: sessionId,
        cli: cli,
        filePath: filePath,
        turns: turns.length,
        indexedAt: indexedAt,
        modifiedAt: modifiedAt,
        size: size,
        resumePoint: resumePoint,
      );
      _bumpGeneration();
    });
  }

  /// Adds [turns] after what [sessionId] already holds — the append-only case,
  /// where a transcript grew and nothing before the resume point changed.
  /// Rows at [fromOrdinal] and past are replaced: they were read from a last
  /// record that had no newline yet, and [turns] reads it again.
  void appendTurns({
    required String sessionId,
    required String cli,
    required String filePath,
    required List<ConversationTurn> turns,
    required int fromOrdinal,
    required int heldTurns,
    required DateTime indexedAt,
    required TranscriptResumePoint resumePoint,
    DateTime? modifiedAt,
    int? size,
  }) {
    _db.transaction(() {
      // Rows are inserted in ordinal order, so a provisional tail can only be
      // the newest row: one seek down the session index answers whether there
      // is one, where a filter on ordinal would read the whole conversation.
      statements++;
      final newest = _db.query(
        'SELECT ordinal FROM conversation_turns WHERE session_id = ? '
        'ORDER BY id DESC LIMIT 1;',
        [sessionId],
      );
      var removed = 0;
      if (newest.isNotEmpty &&
          (newest.first['ordinal'] as int) >= fromOrdinal) {
        statements++;
        removed =
            _db.query(
                  'SELECT COUNT(*) AS n FROM conversation_turns '
                  'WHERE session_id = ? AND ordinal >= ?;',
                  [sessionId, fromOrdinal],
                ).first['n']
                as int;
        statements++;
        _db.execute(
          'DELETE FROM conversation_turns '
          'WHERE session_id = ? AND ordinal >= ?;',
          [sessionId, fromOrdinal],
        );
      }
      _insert(sessionId, cli, turns);
      _writeState(
        sessionId: sessionId,
        cli: cli,
        filePath: filePath,
        turns: heldTurns - removed + turns.length,
        indexedAt: indexedAt,
        modifiedAt: modifiedAt,
        size: size,
        resumePoint: resumePoint,
      );
      if (turns.isNotEmpty || removed > 0) _bumpGeneration();
    });
  }

  /// One slice of a first reading, [clear]ing first what an interrupted one
  /// left. Its state row is not touched: [keepTurns] writes it after the last.
  void addTurns({
    required String sessionId,
    required String cli,
    required List<ConversationTurn> turns,
    bool clear = false,
  }) {
    _db.transaction(() {
      if (clear) {
        statements++;
        _db.execute('DELETE FROM conversation_turns WHERE session_id = ?;', [
          sessionId,
        ]);
      }
      _insert(sessionId, cli, turns);
      _bumpGeneration();
    });
  }

  void _insert(String sessionId, String cli, List<ConversationTurn> turns) {
    const batch = kConversationInsertBatch;
    for (var start = 0; start < turns.length; start += batch) {
      final end = (start + batch).clamp(0, turns.length);
      final chunk = turns.sublist(start, end);
      final values = List.filled(chunk.length, '(?, ?, ?, ?, ?, ?)').join(', ');
      final params = <Object?>[];
      for (final turn in chunk) {
        params.addAll([
          sessionId,
          cli,
          turn.ordinal,
          turn.role,
          turn.text,
          turn.at == null ? null : isoFromDate(turn.at!),
        ]);
      }
      statements++;
      _db.execute(
        'INSERT INTO conversation_turns '
        '(session_id, cli, ordinal, role, text, at) VALUES $values;',
        params,
      );
    }
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
    TranscriptResumePoint? resumePoint,
  }) => _writeState(
    sessionId: sessionId,
    cli: cli,
    filePath: filePath,
    turns: turns,
    indexedAt: indexedAt,
    modifiedAt: modifiedAt,
    size: size,
    resumePoint: resumePoint,
  );

  void _writeState({
    required String sessionId,
    required String cli,
    required String filePath,
    required int turns,
    required DateTime indexedAt,
    DateTime? modifiedAt,
    int? size,
    TranscriptResumePoint? resumePoint,
  }) {
    statements++;
    _db.execute(
      'INSERT INTO conversation_index_state '
      '(session_id, cli, file_path, modified_at, size, turns, indexed_at, '
      'read_offset, read_rows, read_anchor, read_head) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(session_id) DO UPDATE SET '
      'cli = excluded.cli, file_path = excluded.file_path, '
      'modified_at = excluded.modified_at, size = excluded.size, '
      'turns = excluded.turns, indexed_at = excluded.indexed_at, '
      'read_offset = excluded.read_offset, read_rows = excluded.read_rows, '
      'read_anchor = excluded.read_anchor, read_head = excluded.read_head;',
      [
        sessionId,
        cli,
        filePath,
        modifiedAt == null ? null : isoFromDate(modifiedAt),
        size,
        turns,
        isoFromDate(indexedAt),
        resumePoint?.end,
        resumePoint?.rows,
        resumePoint?.anchor,
        resumePoint?.head,
      ],
    );
  }

  /// The turns matching [query], capped at [limit], in FTS5's rowid order.
  /// Never throws on user input: [conversationMatchExpression] quotes it.
  List<ConversationHit> search(
    String query, {
    int limit = kConversationSearchLimit,
  }) {
    final match = conversationMatchExpression(query);
    if (match == null) return const [];
    statements++;
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

  /// Conversations with a turn matching [match] — an FTS5 expression the
  /// caller built, never user text — best BM25 first, one row each.
  ///
  /// Only conversations a session or imported record still names: a deleted
  /// session's rows stay in the index, and a result nothing can open is not a
  /// result. [exclude] drops conversations an earlier tier already returned.
  List<RankedConversation> rankConversations(
    String match, {
    SessionSearchFilter filter = const SessionSearchFilter(),
    Set<String> exclude = const {},
    required int limit,
    int candidates = kConversationRankCandidates,
  }) {
    final where = <String>['conversation_turns_fts MATCH ?'];
    final params = <Object?>[match];
    if (filter.conversationId != null) {
      where.add('t.session_id = ?');
      params.add(filter.conversationId);
    }
    if (filter.cli != null) {
      where.add('t.cli = ?');
      params.add(filter.cli);
    }
    if (filter.after != null) {
      where.add('t.at >= ?');
      params.add(isoFromDate(filter.after!));
    }
    if (filter.before != null) {
      where.add('t.at < ?');
      params.add(isoFromDate(filter.before!));
    }
    final repositories = filter.repositoryId != null
        ? '(?)'
        : filter.projectId != null
        ? '(SELECT id FROM repositories WHERE project_id = ?)'
        : null;
    if (repositories != null) {
      final scope = filter.repositoryId ?? filter.projectId;
      where.add(
        '(t.session_id IN (SELECT external_session_id FROM sessions '
        'WHERE repository_id IN $repositories) '
        'OR t.session_id IN (SELECT external_id FROM imported_sessions '
        'WHERE repository_id IN $repositories) '
        // An earlier agent's part of a switched thread.
        'OR t.session_id IN (SELECT sp.external_session_id '
        'FROM session_agent_spans sp JOIN sessions s ON s.id = sp.session_id '
        'WHERE s.repository_id IN $repositories))',
      );
      params.addAll([scope, scope, scope]);
    }
    if (exclude.isNotEmpty) {
      where.add(
        't.session_id NOT IN (${List.filled(exclude.length, '?').join(', ')})',
      );
      params.addAll(exclude);
    }
    params.add(candidates);
    final head = List.of(params);
    // MATERIALIZED, because bm25() is only callable in the full-text query
    // itself: flattened into the GROUP BY, SQLite refuses it. ORDER BY rowid is
    // one FTS5 serves in index order, so the LIMIT stops the scan rather than
    // sorting it. And the bare-column rule: with MIN() the other columns come
    // from the row that holds the minimum, so best_id is the best turn's id.
    final sql =
        'WITH h AS MATERIALIZED ('
        'SELECT t.session_id AS session_id, t.cli AS cli, t.id AS id, '
        'bm25(conversation_turns_fts) AS score '
        'FROM conversation_turns_fts '
        'JOIN conversation_turns t ON t.id = conversation_turns_fts.rowid '
        'WHERE ${where.join(' AND ')} '
        'ORDER BY conversation_turns_fts.rowid DESC LIMIT ?) '
        'SELECT g.session_id AS session_id, g.cli AS cli, '
        'g.best_id AS best_id, g.score AS score, g.matches AS matches, '
        'state.indexed_at AS indexed_at FROM ('
        'SELECT h.session_id AS session_id, h.cli AS cli, h.id AS best_id, '
        'MIN(h.score) AS score, COUNT(*) AS matches FROM h '
        'GROUP BY h.session_id ORDER BY score, h.session_id LIMIT ?) g '
        'LEFT JOIN conversation_index_state state '
        'ON state.session_id = g.session_id '
        'ORDER BY g.score, g.session_id;';
    // Whether a conversation can still be opened is asked of the page, not of
    // every group: a little over the page is read, and more only when deleted
    // sessions ate into it.
    var pool = limit + 32;
    while (true) {
      statements++;
      final rows = _db.query(sql, [...head, pool]);
      final named = _openable({
        for (final row in rows) row['session_id'] as String,
      });
      final kept = [
        for (final row in rows)
          if (named.contains(row['session_id']))
            (
              sessionId: row['session_id'] as String,
              cli: row['cli'] as String,
              bestTurnId: row['best_id'] as int,
              score: (row['score'] as num).toDouble(),
              matches: row['matches'] as int,
              indexedAt: row['indexed_at'] == null
                  ? null
                  : dateFromIso(row['indexed_at']),
            ),
      ];
      if (kept.length >= limit || rows.length < pool) {
        return kept.take(limit).toList();
      }
      pool *= 4;
    }
  }

  /// The session holding each of [conversationIds] that only a switched
  /// thread's earlier span names — no row names it by that id any more.
  Map<String, String> switchedRowsOf(Iterable<String> conversationIds) {
    final ids = conversationIds.toSet();
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(', ');
    statements++;
    return {
      for (final row in _db.query(
        'SELECT sp.external_session_id AS id, sp.session_id AS row_id '
        'FROM session_agent_spans sp '
        'WHERE sp.external_session_id IN ($marks) '
        'AND NOT EXISTS (SELECT 1 FROM sessions s '
        'WHERE s.external_session_id = sp.external_session_id);',
        [...ids],
      ))
        row['id'] as String: row['row_id'] as String,
    };
  }

  /// Which of [conversationIds] a session or imported record still names.
  Set<String> _openable(Set<String> conversationIds) {
    if (conversationIds.isEmpty) return const {};
    final marks = List.filled(conversationIds.length, '?').join(', ');
    statements++;
    return {
      for (final row in _db.query(
        'SELECT external_session_id AS id FROM sessions '
        'WHERE external_session_id IN ($marks) '
        'UNION SELECT external_id FROM imported_sessions '
        'WHERE external_id IN ($marks) '
        'UNION SELECT external_session_id FROM session_agent_spans '
        'WHERE external_session_id IN ($marks);',
        [...conversationIds, ...conversationIds, ...conversationIds],
      ))
        row['id'] as String,
    };
  }

  /// The indexed turns [turnIds], by primary key — what an excerpt is cut
  /// from. Not a full-text query: `snippet()` would redo a prefix expansion
  /// for every row, which costs more than the ranking it serves.
  Map<int, ({int ordinal, String role, DateTime? at, String text})> turnsById(
    List<int> turnIds,
  ) {
    if (turnIds.isEmpty) return const {};
    statements++;
    return {
      for (final row in _db.query(
        'SELECT id, ordinal, role, at, text FROM conversation_turns '
        'WHERE id IN (${List.filled(turnIds.length, '?').join(', ')});',
        turnIds,
      ))
        row['id'] as int: (
          ordinal: row['ordinal'] as int,
          role: row['role'] as String,
          at: row['at'] == null ? null : dateFromIso(row['at']),
          text: row['text'] as String,
        ),
    };
  }

  /// How many indexed turns hold [term], or with [prefix] any term starting
  /// with it. The vocabulary is FTS5's own, so it is already lower-cased.
  int documentsWith(String term, {bool prefix = false}) {
    statements++;
    final rows = prefix
        ? _db.query(
            'SELECT doc FROM conversation_turns_vocab '
            'WHERE term >= ? AND term < ? LIMIT 1;',
            [term, '$term\u{10FFFF}'],
          )
        : _db.query(
            'SELECT doc FROM conversation_turns_vocab WHERE term = ?;',
            [term],
          );
    return rows.isEmpty ? 0 : rows.first['doc'] as int;
  }

  /// Every indexed term in [from, to), with how many turns hold it.
  List<({String term, int docs})> termsBetween(String from, String to) {
    statements++;
    return [
      for (final row in _db.query(
        'SELECT term, doc FROM conversation_turns_vocab '
        'WHERE term >= ? AND term < ?;',
        [from, to],
      ))
        (term: row['term'] as String, docs: row['doc'] as int),
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

  /// The conversations a session row runs that the index has a path for —
  /// what a search catches up on before it answers.
  List<({String sessionId, String cli, String filePath})>
  indexedSessionConversations() {
    statements++;
    return [
      for (final row in _db.query(
        'SELECT state.session_id AS session_id, state.cli AS cli, '
        'state.file_path AS file_path FROM conversation_index_state state '
        'WHERE EXISTS (SELECT 1 FROM sessions s '
        'WHERE s.external_session_id = state.session_id) '
        'OR EXISTS (SELECT 1 FROM session_agent_spans sp '
        'WHERE sp.external_session_id = state.session_id);',
      ))
        (
          sessionId: row['session_id'] as String,
          cli: row['cli'] as String,
          filePath: row['file_path'] as String,
        ),
    ];
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
        "AND s.external_session_id <> '' "
        // Each earlier agent of a switched thread, under its own agent.
        'UNION SELECT sp.external_session_id, a.agent_kind '
        'FROM session_agent_spans sp '
        'JOIN agent_installations a ON a.id = sp.agent_installation_id '
        "WHERE sp.external_session_id IS NOT NULL "
        "AND sp.external_session_id <> '';",
      ))
        (sessionId: row['session_id'] as String, cli: row['cli'] as String),
    ];
  }

  /// What is known about [conversationId] before it is read: the agent that
  /// writes it and, when the imported history recorded one, its transcript.
  /// The index's own watermark first, then the imported record, then the
  /// session row's installation.
  ({String? cli, String? filePath}) knownOf(String conversationId) {
    statements++;
    final rows = _db.query(
      'SELECT cli, file_path FROM conversation_index_state '
      'WHERE session_id = ? '
      'UNION ALL SELECT source, file_path FROM imported_sessions '
      'WHERE external_id = ? '
      'UNION ALL SELECT a.agent_kind, NULL FROM sessions s '
      'JOIN agent_installations a ON a.id = s.agent_installation_id '
      'WHERE s.external_session_id = ? '
      'UNION ALL SELECT a.agent_kind, NULL FROM session_agent_spans sp '
      'JOIN agent_installations a ON a.id = sp.agent_installation_id '
      'WHERE sp.external_session_id = ? LIMIT 1;',
      [conversationId, conversationId, conversationId, conversationId],
    );
    if (rows.isEmpty) return (cli: null, filePath: null);
    return (
      cli: rows.first['cli'] as String?,
      filePath: rows.first['file_path'] as String?,
    );
  }

  /// [sessionId]'s indexed turns in the order said, from ordinal [from],
  /// at most [limit] of them.
  List<ConversationTurn> turnsOf(
    String sessionId, {
    int from = 0,
    int limit = 200,
  }) {
    statements++;
    return [
      for (final row in _db.query(
        'SELECT ordinal, role, text, at FROM conversation_turns '
        'WHERE session_id = ? AND ordinal >= ? ORDER BY id LIMIT ?;',
        [sessionId, from, limit],
      ))
        ConversationTurn(
          ordinal: row['ordinal'] as int,
          role: row['role'] as String,
          text: row['text'] as String,
          at: row['at'] == null ? null : dateFromIso(row['at']),
        ),
    ];
  }

  /// Conversations read at least once, and the turns held.
  ({int conversations, int turns}) counts() {
    statements++;
    final row = _db
        .query(
          'SELECT (SELECT COUNT(*) FROM conversation_index_state) AS c, '
          '(SELECT COUNT(*) FROM conversation_turns) AS t;',
        )
        .first;
    return (conversations: row['c'] as int, turns: row['t'] as int);
  }

  /// When the one-off backfill finished, or null before it has.
  DateTime? get backfilledAt {
    statements++;
    final value = _db.readMetadata(kConversationIndexBackfilledAtKey);
    return value == null ? null : DateTime.tryParse(value)?.toUtc();
  }

  void markBackfilled(DateTime at) {
    statements++;
    _db.writeMetadata(kConversationIndexBackfilledAtKey, isoFromDate(at));
  }

  ConversationIndexState _stateFromRow(Map<String, Object?> row) {
    final offset = row['read_offset'] as int?;
    final rows = row['read_rows'] as int?;
    return ConversationIndexState(
      sessionId: row['session_id'] as String,
      cli: row['cli'] as String,
      filePath: row['file_path'] as String,
      modifiedAt: row['modified_at'] == null
          ? null
          : dateFromIso(row['modified_at']),
      size: row['size'] as int?,
      turns: row['turns'] as int,
      indexedAt: dateFromIso(row['indexed_at']),
      resumePoint: offset == null || rows == null
          ? null
          : TranscriptResumePoint(
              end: offset,
              rows: rows,
              anchor: _bytes(row['read_anchor']),
              head: _bytes(row['read_head']),
            ),
    );
  }

  static Uint8List? _bytes(Object? value) => switch (value) {
    Uint8List bytes => bytes,
    List<int> bytes => Uint8List.fromList(bytes),
    _ => null,
  };
}
