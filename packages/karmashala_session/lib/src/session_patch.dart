import 'package:agent_cli/process.dart';
import 'session.dart';
import 'session_launch.dart';
import 'session_status.dart';

/// A change a client asks of one session row: the columns it names, each to a
/// value — null included, for the columns where none is a value (a pane, a
/// permission mode, a model, a directory). Applied by the server before it
/// writes and by a client to its own copy the moment it asks ([applyTo]), so
/// the two cannot disagree.
///
/// A patch touches only what it names: a rename can never move a pane, a view
/// flip never touches the worktree the archive service removes. The row's
/// identity, where it was created and who spawned it are never patched.
final class SessionPatch {
  const SessionPatch._(this._fields);

  /// Names no column: changes nothing.
  static const none = SessionPatch._({});

  /// The title the user or a CLI gave it. [byUser] is what stops the CLI
  /// rename sync ever replacing it.
  SessionPatch.rename(String title, {bool byUser = false})
    : this._({_title: title, _titleByUser: byUser});

  SessionPatch.status(SessionStatus status)
    : this._({_status: status.name});

  /// The pane it runs in, or none.
  SessionPatch.pane(String? paneId) : this._({_paneId: paneId});

  SessionPatch.view(SessionView view) : this._({_view: view.name});

  /// Its worktree archived away at [at]. Nothing else: the transcript still
  /// points at this row.
  SessionPatch.archive(DateTime at)
    : this._({_archivedAt: at.toUtc().toIso8601String()});

  /// The permission mode chosen for it, verbatim, or null to follow the
  /// agent's default live.
  SessionPatch.permissionMode(String? mode) : this._({_permissionMode: mode});

  /// The model chosen for it, or null to follow the default. `''` is null:
  /// only one of them reads back as "none".
  SessionPatch.model(String? modelId)
    : this._({_modelId: modelId == null || modelId.isEmpty ? null : modelId});

  /// The directory its agent actually runs in — never the worktree.
  SessionPatch.directory(EnvironmentPath? directory)
    : this._({_workingDirectory: directory == null ? null : _path(directory)});

  /// The CLI conversation it is on.
  SessionPatch.attribute(String externalSessionId)
    : this._({_externalSessionId: externalSessionId});

  /// Its worktree, recorded once the tree exists.
  SessionPatch.worktree({required bool useWorktree, EnvironmentPath? worktree})
    : this._({
        _useWorktree: useWorktree,
        _worktree: worktree == null ? null : _path(worktree),
      });

  static const _title = 'title';
  static const _titleByUser = 'titleByUser';
  static const _status = 'status';
  static const _paneId = 'paneId';
  static const _view = 'view';
  static const _archivedAt = 'archivedAt';
  static const _permissionMode = 'permissionMode';
  static const _modelId = 'modelId';
  static const _workingDirectory = 'workingDirectory';
  static const _externalSessionId = 'externalSessionId';
  static const _useWorktree = 'useWorktree';
  static const _worktree = 'worktree';

  static const _known = {
    _title,
    _titleByUser,
    _status,
    _paneId,
    _view,
    _archivedAt,
    _permissionMode,
    _modelId,
    _workingDirectory,
    _externalSessionId,
    _useWorktree,
    _worktree,
  };

  final Map<String, Object?> _fields;

  /// This patch and then [other]'s columns over it.
  SessionPatch and(SessionPatch other) =>
      SessionPatch._({..._fields, ...other._fields});

  /// The same patch without the status it names — what a server that records
  /// the session's lifecycle itself applies.
  SessionPatch withoutStatus() =>
      SessionPatch._({..._fields}..remove(_status));

  bool get isEmpty => _fields.isEmpty;

  /// The status this patch sets, or null when it sets none.
  SessionStatus? get status => _fields.containsKey(_status)
      ? SessionStatus.values.asNameMap()[_fields[_status]]
      : null;

  /// The title this patch sets, or null when it sets none.
  String? get title => _fields[_title] as String?;

  Map<String, Object?> toJson() => Map.of(_fields);

  /// Throws [FormatException] on a patch out of shape: an unknown column, or
  /// a value of the wrong kind.
  static SessionPatch fromJson(Map<String, Object?> json) {
    for (final key in json.keys) {
      if (!_known.contains(key)) {
        throw FormatException('a session patch has no column "$key"');
      }
    }
    final patch = SessionPatch._(Map.of(json));
    // Every value read once, so a bad one is refused here, not at the write.
    patch.applyTo(
      Session(
        id: '-',
        repositoryId: '-',
        agentInstallationId: '-',
        title: '-',
        useWorktree: false,
        status: SessionStatus.created,
        createdAt: DateTime.utc(2000),
      ),
    );
    return patch;
  }

  /// [row] with this patch's columns written.
  Session applyTo(Session row) {
    T? read<T>(String key) {
      final value = _fields[key];
      if (value == null || value is T) return value as T?;
      throw FormatException('a session patch\'s "$key" is out of shape');
    }

    bool has(String key) => _fields.containsKey(key);
    return Session(
      id: row.id,
      repositoryId: row.repositoryId,
      agentInstallationId: row.agentInstallationId,
      title: read<String>(_title) ?? row.title,
      useWorktree: read<bool>(_useWorktree) ?? row.useWorktree,
      worktree: has(_worktree) ? _pathOf(_fields[_worktree]) : row.worktree,
      workingDirectory: has(_workingDirectory)
          ? _pathOf(_fields[_workingDirectory])
          : row.workingDirectory,
      status: has(_status)
          ? (SessionStatus.values.asNameMap()[read<String>(_status)] ??
                (throw const FormatException('not a session status')))
          : row.status,
      createdAt: row.createdAt,
      externalSessionId: has(_externalSessionId)
          ? read<String>(_externalSessionId)
          : row.externalSessionId,
      parentSessionId: row.parentSessionId,
      parentLink: row.parentLink,
      paneId: has(_paneId) ? read<String>(_paneId) : row.paneId,
      surface: row.surface,
      view: has(_view)
          ? (SessionView.values.asNameMap()[read<String>(_view)] ??
                (throw const FormatException('not a session view')))
          : row.view,
      permissionMode: has(_permissionMode)
          ? read<String>(_permissionMode)
          : row.permissionMode,
      modelId: has(_modelId) ? _modelOf(read<String>(_modelId)) : row.modelId,
      archivedAt: has(_archivedAt)
          ? _dateOf(read<String>(_archivedAt))
          : row.archivedAt,
      titleByUser: read<bool>(_titleByUser) ?? row.titleByUser,
    );
  }

  static String? _modelOf(String? modelId) =>
      modelId == null || modelId.isEmpty ? null : modelId;

  static DateTime? _dateOf(String? iso) =>
      iso == null ? null : DateTime.parse(iso).toUtc();

  static Map<String, Object?> _path(EnvironmentPath path) => {
    'environmentId': path.environmentId,
    'path': path.path,
  };

  static EnvironmentPath? _pathOf(Object? json) {
    if (json == null) return null;
    if (json is Map &&
        json['environmentId'] is String &&
        json['path'] is String) {
      return EnvironmentPath(
        environmentId: json['environmentId'] as String,
        path: json['path'] as String,
      );
    }
    throw const FormatException('not a path in an environment');
  }

  @override
  String toString() => 'SessionPatch(${_fields.keys.join(', ')})';
}

/// Why [title] cannot name a session, or null when it can.
String? sessionTitleProblem(String title) =>
    title.trim().isEmpty ? 'a session needs a title' : null;
