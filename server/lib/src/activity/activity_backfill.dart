import 'dart:convert';

import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

import 'activity_log.dart';

/// The app-metadata key holding the backfill's place: the phase, the last
/// row of it done, and when it finished.
const String kActivityBackfillKey = 'activity_backfill.v1';

/// One phase's step: the entries for the rows after `after`, and the last
/// row read — null once there are no more.
typedef _Step = Future<({List<ActivityDraft> drafts, int? last})> Function(
  int after,
);

/// **The activity log's backfill**: what the store already held before the
/// log existed, recovered once and marked so. Chunked, with its place saved
/// after every chunk, so a large store never stalls start-up and a restart
/// resumes; keyed by source and source id, so nothing is written twice.
/// Nothing is invented: a time read off a row is exact, one inferred from
/// neighbours is approximate, and what no row records is left out.
class ActivityBackfill {
  ActivityBackfill(
    this._db, {
    required ActivityLog log,
    required this.messagesOf,
    this.chunk = 50,
    this.pause = const Duration(milliseconds: 20),
    this.onWritten,
  }) : _log = log;

  final AppDatabase _db;
  final ActivityLog _log;

  /// A session's transcript, native or imported, by the server's one reader.
  final Future<List<TranscriptMessage>> Function(String sessionId) messagesOf;
  final int chunk;

  /// Between chunks, so the store is never held for long.
  final Duration pause;

  /// Entries were written: clients may be told.
  final void Function()? onWritten;

  late final List<(String, _Step)> _phases = [
    ('sessions', _sessions),
    ('delegations', _delegations),
    ('transcripts', _transcripts),
    ('imported', _imported),
    ('checkpoints', _checkpoints),
    ('decisions', _decisions),
    ('resumes', _resumes),
    ('ends', _ends),
  ];

  Map<String, Object?> get _state {
    try {
      final raw = _db.readMetadata(kActivityBackfillKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Started over: every write is keyed, so that is safe.
    }
    return const {};
  }

  bool get isDone => _state['done'] != null;

  /// Runs what is left; answers how many entries were written. Stops early,
  /// with its place saved, when [shouldStop] says so after a chunk.
  Future<int> run({bool Function()? shouldStop}) async {
    final state = _state;
    if (state['done'] != null) return 0;
    var phase = _phases.indexWhere((p) => p.$1 == state['phase']);
    var after = state['after'] is int ? state['after']! as int : 0;
    if (phase < 0) {
      phase = 0;
      after = 0;
    }
    var written = 0;
    while (phase < _phases.length) {
      final (_, step) = _phases[phase];
      final result = await step(after);
      if (result.drafts.isNotEmpty) {
        written += _log.append(result.drafts).length;
        onWritten?.call();
      }
      final last = result.last;
      if (last == null) {
        phase++;
        after = 0;
      } else {
        after = last;
      }
      _db.writeMetadata(
        kActivityBackfillKey,
        jsonEncode(
          phase < _phases.length
              ? {'phase': _phases[phase].$1, 'after': after}
              : {'done': DateTime.now().toUtc().toIso8601String()},
        ),
      );
      if (phase < _phases.length && (shouldStop?.call() ?? false)) break;
      if (last != null && pause > Duration.zero) {
        await Future<void>.delayed(pause);
      }
    }
    return written;
  }

  List<Map<String, Object?>> _rows(String sql, int after) =>
      _db.query(sql, [after, chunk]);

  static DateTime? _at(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;

  ({List<ActivityDraft> drafts, int? last}) _page(
    List<Map<String, Object?>> rows,
    Iterable<ActivityDraft> Function(Map<String, Object?> row) draftsOf,
  ) => (
    drafts: [for (final row in rows) ...draftsOf(row)],
    last: rows.isEmpty ? null : rows.last['rid']! as int,
  );

  ActivityDraft _draft(
    String sessionId,
    ActivityKind kind,
    DateTime at, {
    required String source,
    required String sourceId,
    bool approximate = false,
    String? detail,
    String? parent,
  }) => ActivityDraft(
    at: at,
    kind: kind,
    sessionId: sessionId,
    source: source,
    sourceId: sourceId,
    backfilled: true,
    approximate: approximate,
    detail: detail,
    parentSessionId: parent,
  );

  /// A row's start, its archive and its parent link — the keys the v79
  /// triggers use, so a row they already logged is not logged again.
  Future<({List<ActivityDraft> drafts, int? last})> _sessions(int after) async =>
      _page(
        _rows(
          'SELECT rowid AS rid, id, created_at, archived_at, '
          'parent_session_id, parent_link_kind FROM sessions '
          'WHERE rowid > ? ORDER BY rowid LIMIT ?;',
          after,
        ),
        (row) sync* {
          final id = row['id']! as String;
          final created = _at(row['created_at']);
          if (created == null) return;
          yield _draft(
            id,
            ActivityKind.sessionStarted,
            created,
            source: 'session',
            sourceId: '$id:started',
          );
          final archivedRaw = row['archived_at'];
          final archived = _at(archivedRaw);
          if (archived != null) {
            yield _draft(
              id,
              ActivityKind.archived,
              archived,
              source: 'session',
              sourceId: '$id:archived:$archivedRaw',
            );
          }
          final parent = row['parent_session_id'];
          if (parent is String) {
            yield _draft(
              id,
              ActivityKind.linked,
              created,
              source: 'lineage',
              sourceId: id,
              parent: parent,
              detail: row['parent_link_kind'] as String?,
            );
          }
        },
      );

  /// A delegation's own time, for a child linked without a parent column.
  Future<({List<ActivityDraft> drafts, int? last})> _delegations(
    int after,
  ) async => _page(
    _rows(
      'SELECT rowid AS rid, child_session_id, parent_session_id, delegated_at '
      'FROM session_delegations WHERE rowid > ? ORDER BY rowid LIMIT ?;',
      after,
    ),
    (row) sync* {
      final at = _at(row['delegated_at']);
      if (at == null) return;
      final child = row['child_session_id']! as String;
      yield _draft(
        child,
        ActivityKind.linked,
        at,
        source: 'lineage',
        sourceId: child,
        parent: row['parent_session_id']! as String,
        detail: 'delegated',
      );
    },
  );

  Future<({List<ActivityDraft> drafts, int? last})> _transcripts(
    int after,
  ) => _fromTranscripts(
    _rows(
      'SELECT rowid AS rid, id FROM sessions WHERE rowid > ? '
      'ORDER BY rowid LIMIT ?;',
      after,
    ),
    imported: false,
  );

  Future<({List<ActivityDraft> drafts, int? last})> _imported(int after) =>
      _fromTranscripts(
        _rows(
          'SELECT rowid AS rid, id FROM imported_sessions WHERE rowid > ? '
          'ORDER BY rowid LIMIT ?;',
          after,
        ),
        imported: true,
      );

  Future<({List<ActivityDraft> drafts, int? last})> _fromTranscripts(
    List<Map<String, Object?>> rows, {
    required bool imported,
  }) async {
    final drafts = <ActivityDraft>[];
    for (final row in rows) {
      final id = row['id']! as String;
      List<TranscriptMessage> messages;
      try {
        messages = await messagesOf(id);
      } on Object {
        // An unreadable record costs its session, not the run.
        continue;
      }
      drafts.addAll(turnsOf(id, messages, imported: imported));
    }
    return (
      drafts: drafts,
      last: rows.isEmpty ? null : rows.last['rid']! as int,
    );
  }

  /// [sessionId]'s turns as its transcript dates them: each starts at its
  /// prompt, and ends — approximately — at the last reply before the next.
  /// An imported session starts, approximately, at its first dated line.
  static List<ActivityDraft> turnsOf(
    String sessionId,
    List<TranscriptMessage> messages, {
    bool imported = false,
  }) {
    final dated = [
      for (final m in messages)
        if (m.at != null && !m.queued) m,
    ];
    if (dated.isEmpty) return const [];
    ActivityDraft draft(ActivityKind kind, DateTime at, String key,
            {bool approximate = false}) =>
        ActivityDraft(
          at: at.toUtc(),
          kind: kind,
          sessionId: sessionId,
          source: 'transcript',
          sourceId: '$sessionId:$key',
          backfilled: true,
          approximate: approximate,
        );
    final drafts = <ActivityDraft>[
      if (imported)
        draft(
          ActivityKind.sessionStarted,
          dated.first.at!,
          'started',
          approximate: true,
        ),
    ];
    var turn = -1;
    var prompting = false;
    DateTime? lastReply;
    void close() {
      final end = lastReply;
      if (turn >= 0 && end != null) {
        drafts.add(
          draft(ActivityKind.turnEnded, end, '$turn:end', approximate: true),
        );
      }
    }

    for (final message in dated) {
      final prompt = message.role == 'user' || message.role == 'command';
      if (prompt) {
        if (prompting) continue;
        close();
        turn++;
        prompting = true;
        lastReply = null;
        drafts.add(draft(ActivityKind.turnStarted, message.at!, '$turn:start'));
      } else {
        prompting = false;
        if (turn >= 0) lastReply = message.at;
      }
    }
    close();
    return drafts;
  }

  /// Turn-start and turn-end captures, for a session no transcript dated.
  Future<({List<ActivityDraft> drafts, int? last})> _checkpoints(
    int after,
  ) async {
    final rows = _rows(
      'SELECT rowid AS rid, id, session_id, reason, created_at '
      'FROM session_checkpoints WHERE rowid > ? ORDER BY rowid LIMIT ?;',
      after,
    );
    final dated = <String, bool>{};
    return _page(rows, (row) sync* {
      final sessionId = row['session_id']! as String;
      final kind = switch (row['reason']) {
        'turnStart' => ActivityKind.turnStarted,
        'turn' => ActivityKind.turnEnded,
        _ => null,
      };
      final at = _at(row['created_at']);
      if (kind == null || at == null) return;
      final hasTranscript = dated[sessionId] ??= _db
          .query(
            "SELECT 1 FROM activity_log WHERE session_id = ? AND source = "
            "'transcript' LIMIT 1;",
            [sessionId],
          )
          .isNotEmpty;
      if (hasTranscript) return;
      yield _draft(
        sessionId,
        kind,
        at,
        source: 'checkpoint',
        sourceId: row['id']! as String,
      );
    });
  }

  /// An answered approval: when a wait ended. When it began is not kept.
  Future<({List<ActivityDraft> drafts, int? last})> _decisions(
    int after,
  ) async => _page(
    _rows(
      'SELECT rowid AS rid, id, session_id, summary, recorded_at '
      "FROM session_decisions WHERE rowid > ? AND origin_kind = "
      "'approvalPrompt' ORDER BY rowid LIMIT ?;",
      after,
    ),
    (row) sync* {
      final at = _at(row['recorded_at']);
      if (at == null) return;
      final summary = '${row['summary']}'.replaceAll(RegExp(r'\s+'), ' ');
      yield _draft(
        row['session_id']! as String,
        ActivityKind.waitEnded,
        at,
        source: 'decision',
        sourceId: '${row['id']}',
        detail: summary.length <= 120 ? summary : '${summary.substring(0, 119)}…',
      );
    },
  );

  /// A scheduled resume: armed as the limit was met, so the pause begins
  /// about then; done, it resumed when it finished.
  Future<({List<ActivityDraft> drafts, int? last})> _resumes(
    int after,
  ) async => _page(
    _rows(
      'SELECT rowid AS rid, id, session_id, scheduled_at, finished_at, state, '
      'window_label FROM scheduled_resumes WHERE rowid > ? '
      'ORDER BY rowid LIMIT ?;',
      after,
    ),
    (row) sync* {
      final id = row['id']! as String;
      final sessionId = row['session_id']! as String;
      final scheduled = _at(row['scheduled_at']);
      if (scheduled != null) {
        yield _draft(
          sessionId,
          ActivityKind.limitPaused,
          scheduled,
          source: 'resume',
          sourceId: '$id:paused',
          approximate: true,
          detail: row['window_label'] as String?,
        );
      }
      final finished = _at(row['finished_at']);
      if (finished != null && row['state'] == 'done') {
        yield _draft(
          sessionId,
          ActivityKind.limitResumed,
          finished,
          source: 'resume',
          sourceId: '$id:resumed',
        );
      }
    },
  );

  /// A finished row's end, which no column dates: approximately its last
  /// known activity, and only when that is after its start.
  Future<({List<ActivityDraft> drafts, int? last})> _ends(int after) async =>
      _page(
        _rows(
          'SELECT s.rowid AS rid, s.id, s.status, '
          '(SELECT MAX(at) FROM activity_log l WHERE l.session_id = s.id) '
          'AS last_at, '
          "(SELECT MIN(at) FROM activity_log l WHERE l.session_id = s.id "
          "AND l.kind = 'sessionStarted') AS started_at, "
          "(SELECT COUNT(*) FROM activity_log l WHERE l.session_id = s.id "
          "AND l.kind = 'sessionEnded') AS ends "
          'FROM sessions s WHERE s.rowid > ? ORDER BY s.rowid LIMIT ?;',
          after,
        ),
        (row) sync* {
          const finished = {'completed', 'failed', 'cancelled'};
          if (!finished.contains(row['status']) || row['ends'] != 0) return;
          final last = _at(row['last_at']);
          final started = _at(row['started_at']);
          if (last == null || started == null || !last.isAfter(started)) {
            return;
          }
          final id = row['id']! as String;
          yield _draft(
            id,
            ActivityKind.sessionEnded,
            last,
            source: 'end',
            sourceId: id,
            approximate: true,
            detail: row['status']! as String,
          );
        },
      );
}
