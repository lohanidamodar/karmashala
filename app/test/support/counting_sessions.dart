import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala_session/session.dart';

/// **The unit the cost tests price since slice 1c**: a read of the sessions.
///
/// Sessions are no longer read from SQLite — every read goes to the app's
/// copy of the server's rows through `SessionsData` and
/// `ImportedSessionsData`. [countedSessionsOverrides] swaps both for copies
/// that record each read by method in a [SessionReadLog], so a cost test
/// still says how many reads one change cost and how many rows they handed
/// back. A "table scan" is a whole-list `getAll`.
///
/// The counted copies announce no *server* change as a session signal (the
/// production provider does); a cost test writes from this app, or bumps by
/// hand, so nothing it measures depends on that.
class SessionReadLog {
  /// Each read, by method name; the imported history's are prefixed so a
  /// filter can tell them apart.
  final reads = <String>[];

  /// Rows (or entries) the reads handed back.
  int rows = 0;

  int get count => reads.length;

  /// Whole-list reads — what a one-row change must never pay for.
  int get tableScans => reads.where((r) => r.startsWith('getAll')).length;

  void reset() {
    reads.clear();
    rows = 0;
  }

  T record<T>(String read, T answer) {
    reads.add(read);
    rows += switch (answer) {
      final Iterable<Object?> list => list.length,
      final Map<Object?, Object?> map => map.length,
      null => 0,
      _ => 1,
    };
    return answer;
  }
}

/// Overrides for a container whose session reads [log] records.
List<Override> countedSessionsOverrides(SessionReadLog log) => [
  sessionsDataProvider.overrideWith(
    (ref) => CountingSessions(ref.watch(dataClientProvider), log),
  ),
  importedSessionsProvider.overrideWith(
    (ref) => CountingImportedSessions(
      ref.watch(dataClientProvider),
      ref.watch(sessionsDataProvider),
      log,
    ),
  ),
];

/// The sessions copy, each read recorded in [_log].
class CountingSessions extends SessionsData {
  CountingSessions(super.client, this._log);

  final SessionReadLog _log;

  @override
  Session? getById(String id) => _log.record('getById', super.getById(id));
  @override
  List<Session> getAll() => _log.record('getAll', super.getAll());
  @override
  List<Session> getByIds(Iterable<String> ids) =>
      _log.record('getByIds', super.getByIds(ids));
  @override
  List<Session> getByPaneIds(Iterable<String> paneIds) =>
      _log.record('getByPaneIds', super.getByPaneIds(paneIds));
  @override
  Map<String, String> paneSessionIds() =>
      _log.record('paneSessionIds', super.paneSessionIds());
  @override
  Map<String, String> repositoryIdsById() =>
      _log.record('repositoryIdsById', super.repositoryIdsById());
  @override
  List<Session> getClaimingLive() =>
      _log.record('getClaimingLive', super.getClaimingLive());
  @override
  List<Session> getAllByExternalSessionId(String externalSessionId) =>
      _log.record(
        'getAllByExternalSessionId',
        super.getAllByExternalSessionId(externalSessionId),
      );
  @override
  Session? getByExternalSessionId(String externalSessionId) => _log.record(
    'getByExternalSessionId',
    super.getByExternalSessionId(externalSessionId),
  );
  @override
  Set<String> heldExternalSessionIds({String? excludingSessionId}) =>
      _log.record(
        'heldExternalSessionIds',
        super.heldExternalSessionIds(excludingSessionId: excludingSessionId),
      );
  @override
  List<Session> getWaitingForTitleSync() =>
      _log.record('getWaitingForTitleSync', super.getWaitingForTitleSync());
  @override
  List<Session> getUnattributed() =>
      _log.record('getUnattributed', super.getUnattributed());
  @override
  ({int sessions, int running}) countsByRepositories(
    Iterable<String> repositoryIds,
  ) => _log.record(
    'countsByRepositories',
    super.countsByRepositories(repositoryIds),
  );
  @override
  List<Session> getByRepository(String repositoryId) =>
      _log.record('getByRepository', super.getByRepository(repositoryId));
  @override
  String? parentOf(String id) => _log.record('parentOf', super.parentOf(id));
  @override
  List<Session> childrenOf(String id) =>
      _log.record('childrenOf', super.childrenOf(id));
}

/// The imported history, each read recorded in [_log].
class CountingImportedSessions extends ImportedSessionsData {
  CountingImportedSessions(super.client, super.sessions, this._log);

  final SessionReadLog _log;

  @override
  ImportedSession? getById(String id) =>
      _log.record('imported.getById', super.getById(id));
  @override
  List<ImportedSession> getAll() =>
      _log.record('getAll imported', super.getAll());
  @override
  Map<String, String> repositoryIdsById() =>
      _log.record('imported.repositoryIdsById', super.repositoryIdsById());
  @override
  int countByRepositories(Iterable<String> repositoryIds) => _log.record(
    'imported.countByRepositories',
    super.countByRepositories(repositoryIds),
  );
  @override
  List<ImportedSession> getByRepository(String repositoryId) => _log.record(
    'imported.getByRepository',
    super.getByRepository(repositoryId),
  );
}
