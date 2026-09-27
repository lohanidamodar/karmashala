import 'package:karmashala_browser/browser.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';

/// The `browser.consent.v1` grants, read from the store on every call — the
/// preference a person sets in any client's Settings, which the server
/// writes through the data API. The server itself only reads it.
class StoreConsentJournal implements ConsentJournal {
  const StoreConsentJournal(this._database);

  final AppDatabase _database;

  @override
  String? read(String key) => _database.readMetadata(key);

  @override
  void write(String key, String value) => _database.writeMetadata(key, value);
}

/// Which project a browser tool call belongs to: the calling session's
/// checkout's project. The app also fell back to the checkout its Explorer
/// had selected; that selection is one window's UI and does not exist at the
/// server, so a caller with no session gets no scope — and so no grant.
class ServerBrowserConsent {
  ServerBrowserConsent(AppDatabase database)
    : _sessions = SessionDao(database),
      _repositories = RepositoryDao(database),
      _projects = ProjectDao(database),
      _store = BrowserConsentStore(StoreConsentJournal(database));

  final SessionDao _sessions;
  final RepositoryDao _repositories;
  final ProjectDao _projects;
  final BrowserConsentStore _store;

  /// The project [callerSessionId] works in, or null when it cannot be told.
  ({String id, String name})? scopeOf(String? callerSessionId) {
    if (callerSessionId == null || callerSessionId.isEmpty) return null;
    final repositoryId = _sessions.getById(callerSessionId)?.repositoryId;
    if (repositoryId == null || repositoryId.isEmpty) return null;
    final projectId = _repositories.getById(repositoryId)?.projectId;
    if (projectId == null || projectId.isEmpty) return null;
    return (
      id: projectId,
      name: _projects.getById(projectId)?.name ?? projectId,
    );
  }

  /// The gate for [callerSessionId]: fails closed when no project resolves.
  BrowserConsent consentFor(String? callerSessionId) {
    final scope = scopeOf(callerSessionId);
    if (scope == null) return const DeniedBrowserConsent();
    return ProjectScopedBrowserConsent(store: _store, scope: scope);
  }
}
