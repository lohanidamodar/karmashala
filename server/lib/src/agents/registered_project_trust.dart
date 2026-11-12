import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_session/session.dart'
    show kTrustRegisteredProjectsKey, trustsRegisteredProjects;
import 'package:karmashala_store/database.dart';

/// Writes an agent's trust record for the folder a new conversation starts in.
typedef TrustFolderFor =
    Future<bool> Function(
      AgentInstallation installation,
      EnvironmentPath folder,
    );

/// "Trust registered projects for agents": while it is on, a new conversation
/// in a folder the person registered — a checkout of one of their projects, or
/// a worktree Karmashala made for a session of one — has that folder trusted
/// for its agent first. A folder Karmashala does not know is never trusted.
class RegisteredProjectTrust {
  RegisteredProjectTrust(
    this._db, {
    required TrustFolderFor trust,
    void Function(String message)? log,
  }) : _trust = trust,
       _log = log;

  final AppDatabase _db;
  final TrustFolderFor _trust;
  final void Function(String message)? _log;

  /// Read on every launch, so a change in Settings counts on the next one.
  bool get enabled =>
      trustsRegisteredProjects(_db.readMetadata(kTrustRegisteredProjectsKey));

  /// Whether [folder] is a registered checkout or a session's worktree.
  bool isRegistered(EnvironmentPath folder) {
    final want = _pathKey(folder.path);
    final checkouts = _db.query(
      'SELECT path FROM repositories WHERE environment_id = ?;',
      [folder.environmentId],
    );
    if (checkouts.any((row) => _pathKey(row['path']! as String) == want)) {
      return true;
    }
    final worktrees = _db.query(
      'SELECT worktree_path FROM sessions WHERE worktree_environment_id = ? '
      'AND worktree_path IS NOT NULL;',
      [folder.environmentId],
    );
    return worktrees.any(
      (row) => _pathKey(row['worktree_path']! as String) == want,
    );
  }

  /// Trusts [folder] for [installation]'s agent when the setting is on and
  /// the folder is registered; true when the agent's settings now trust it.
  /// Never throws: a failure is logged and the launch goes on.
  Future<bool> trustForNewConversation(
    AgentInstallation installation,
    EnvironmentPath folder,
  ) async {
    try {
      if (!enabled || !isRegistered(folder)) return false;
      return await _trust(installation, folder);
    } on Object catch (error) {
      _log?.call(
        '${folder.path} could not be marked trusted for '
        '${installation.agentId}: $error',
      );
      return false;
    }
  }
}

final RegExp _drive = RegExp(r'^[A-Za-z]:');

/// [path] spelled one way: a Windows path by its backslashes and in one case,
/// and neither kind with a trailing separator.
String _pathKey(String path) {
  final windows = path.contains(r'\') || _drive.hasMatch(path);
  var key = windows ? path.replaceAll('/', r'\').toLowerCase() : path;
  while (key.length > 1 &&
      (key.endsWith('/') || key.endsWith(r'\')) &&
      !(windows && key.length == 3)) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}
