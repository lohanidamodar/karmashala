import 'package:karmashala_session/session.dart';

/// The questions every reader of the `sessions` table asks, answered in the
/// table's orders. The server answers them from its store (`SessionDao`); a
/// client — the desktop app — from its copy of the server's rows
/// ([SessionRowsIndex]). One interface, so a rule written against it runs the
/// same on either side.
abstract interface class SessionReads {
  Session? getById(String id);

  /// Every row, oldest first (`created_at`, then id).
  List<Session> getAll();

  /// The rows named by [ids], oldest first.
  List<Session> getByIds(Iterable<String> ids);

  /// Rows hosted by any of [paneIds], oldest first.
  List<Session> getByPaneIds(Iterable<String> paneIds);

  /// paneId → the oldest session standing in it.
  Map<String, String> paneSessionIds();

  /// sessionId → the repository it targets.
  Map<String, String> repositoryIdsById();

  /// Every row whose status still claims something is running, oldest first.
  List<Session> getClaimingLive();

  /// Every row recording the CLI conversation [externalSessionId], **newest
  /// first**: the column is not unique, so duplicates are real.
  List<Session> getAllByExternalSessionId(String externalSessionId);

  /// The most recently started row for [externalSessionId], or null.
  Session? getByExternalSessionId(String externalSessionId);

  /// Every conversation id some row records, except [excludingSessionId]'s.
  Set<String> heldExternalSessionIds({String? excludingSessionId});

  /// Rows not archived, on a conversation, whose title the user did not type.
  List<Session> getWaitingForTitleSync();

  /// Rows not archived that have no conversation id yet.
  List<Session> getUnattributed();

  /// How many sessions sit under [repositoryIds], and how many are running.
  ({int sessions, int running}) countsByRepositories(
    Iterable<String> repositoryIds,
  );

  /// Sessions targeting [repositoryId], oldest first.
  List<Session> getByRepository(String repositoryId);

  /// The parent of [id], or null for a root session or an unknown id.
  String? parentOf(String id);

  /// Sessions naming [id] as their parent, oldest first.
  List<Session> childrenOf(String id);
}

/// [SessionReads] that can also record a row's lifecycle status — what the
/// recorder writes through.
abstract interface class SessionStatusStore implements SessionReads {
  void updateStatus(String id, SessionStatus status);
}

/// The table's order: `ORDER BY created_at, id`.
int compareSessions(Session a, Session b) {
  final byTime = a.createdAt.compareTo(b.createdAt);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

bool _hasConversation(Session row) =>
    row.externalSessionId != null && row.externalSessionId!.isNotEmpty;

/// [SessionReads] over rows held in memory — a client's copy of the server's
/// rows. [rows] is read on every call that needs the whole set; the sorted
/// list is kept until the rows change — [_version] moves, or [invalidate] is
/// called — so a reader on a timer pays for a sort once per change, not once
/// per read.
class SessionRowsIndex implements SessionReads {
  SessionRowsIndex(this._rows, [this._version]);

  final Map<String, Session> Function() _rows;
  final int Function()? _version;
  List<Session>? _sorted;
  int? _sortedAt;

  /// The rows changed: the next whole-set read sorts again.
  void invalidate() => _sorted = null;

  List<Session> get _all {
    final version = _version?.call();
    if (_sorted == null || version != _sortedAt) {
      _sortedAt = version;
      _sorted = List<Session>.unmodifiable(
        <Session>[..._rows().values]..sort(compareSessions),
      );
    }
    return _sorted!;
  }

  @override
  Session? getById(String id) => _rows()[id];

  @override
  List<Session> getAll() => [..._all];

  @override
  List<Session> getByIds(Iterable<String> ids) {
    final rows = _rows();
    return [
      for (final id in ids.toSet()) ?rows[id],
    ]..sort(compareSessions);
  }

  @override
  List<Session> getByPaneIds(Iterable<String> paneIds) {
    final panes = paneIds.toSet();
    if (panes.isEmpty) return const [];
    return [
      for (final row in _all)
        if (panes.contains(row.paneId)) row,
    ];
  }

  @override
  Map<String, String> paneSessionIds() {
    final byPane = <String, String>{};
    for (final row in _all) {
      final pane = row.paneId;
      if (pane != null) byPane.putIfAbsent(pane, () => row.id);
    }
    return byPane;
  }

  @override
  Map<String, String> repositoryIdsById() => {
    for (final row in _rows().values) row.id: row.repositoryId,
  };

  @override
  List<Session> getClaimingLive() => [
    for (final row in _all)
      if (row.status.claimsLive) row,
  ];

  @override
  List<Session> getAllByExternalSessionId(String externalSessionId) => [
    for (final row in _all.reversed)
      if (row.externalSessionId == externalSessionId) row,
  ];

  @override
  Session? getByExternalSessionId(String externalSessionId) {
    for (final row in _all.reversed) {
      if (row.externalSessionId == externalSessionId) return row;
    }
    return null;
  }

  @override
  Set<String> heldExternalSessionIds({String? excludingSessionId}) => {
    for (final row in _rows().values)
      if (row.id != excludingSessionId && _hasConversation(row))
        row.externalSessionId!,
  };

  @override
  List<Session> getWaitingForTitleSync() => [
    for (final row in _all)
      if (!row.isArchived && !row.titleByUser && _hasConversation(row)) row,
  ];

  @override
  List<Session> getUnattributed() => [
    for (final row in _all)
      if (!row.isArchived && !_hasConversation(row)) row,
  ];

  @override
  ({int sessions, int running}) countsByRepositories(
    Iterable<String> repositoryIds,
  ) {
    final ids = repositoryIds.toSet();
    if (ids.isEmpty) return (sessions: 0, running: 0);
    var sessions = 0;
    var running = 0;
    for (final row in _rows().values) {
      if (!ids.contains(row.repositoryId)) continue;
      sessions++;
      if (row.status == SessionStatus.running) running++;
    }
    return (sessions: sessions, running: running);
  }

  @override
  List<Session> getByRepository(String repositoryId) => [
    for (final row in _all)
      if (row.repositoryId == repositoryId) row,
  ];

  @override
  String? parentOf(String id) => _rows()[id]?.parentSessionId;

  @override
  List<Session> childrenOf(String id) => [
    for (final row in _all)
      if (row.parentSessionId == id) row,
  ];
}
