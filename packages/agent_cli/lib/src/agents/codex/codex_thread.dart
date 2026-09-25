/// Every `sourceKinds` value `thread/list` accepts.
///
/// **Passing this is not optional.** Omit `sourceKinds` and Codex applies its
/// own "interactive sources" default, which on the owner's store answered 11 of
/// 16 real threads — the five `exec` ones vanished. With this list the reply is
/// exactly the 16 rollout files on disk. The names are the server's own, quoted
/// back by the `-32600` it answers an unknown kind with.
const List<String> codexThreadSourceKinds = [
  'cli',
  'vscode',
  'exec',
  'appServer',
  'subAgent',
  'subAgentReview',
  'subAgentCompact',
  'subAgentThreadSpawn',
  'subAgentOther',
  'unknown',
];

/// One row of `thread/list`, in the fields detection uses.
///
/// [cwd] is the *current* working directory — Codex re-stamps it in every
/// `turn_context`, so a thread that changed directory says so here while the
/// rollout's opening `session_meta` still says where it began. [preview] is the
/// first real user message, not the injected preamble a rollout opens with.
class CodexThread {
  const CodexThread({
    required this.id,
    required this.cwd,
    this.name,
    this.preview = '',
    this.path,
    this.createdAt,
    this.updatedAt,
  });

  /// The row, or `null` when it has no id or no `cwd` to file it under.
  static CodexThread? fromJson(Object? row) {
    if (row is! Map) return null;
    final id = row['id'];
    final cwd = row['cwd'];
    if (id is! String || id.isEmpty) return null;
    if (cwd is! String || cwd.isEmpty) return null;
    final name = row['name'];
    final preview = row['preview'];
    final path = row['path'];
    return CodexThread(
      id: id,
      cwd: cwd,
      name: name is String && name.trim().isNotEmpty ? name : null,
      preview: preview is String ? preview : '',
      path: path is String && path.isNotEmpty ? path : null,
      createdAt: _epochSeconds(row['createdAt']),
      updatedAt: _epochSeconds(row['updatedAt']),
    );
  }

  final String id;
  final String cwd;
  final String? name;
  final String preview;

  /// The rollout file, spelled the way **Codex** sees it — a POSIX path inside
  /// the distribution for a WSL store, not something this host can open.
  final String? path;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// `createdAt`, `updatedAt` and `recencyAt` are epoch **seconds**, not
  /// milliseconds; reading them as milliseconds dates every session to 1970.
  static DateTime? _epochSeconds(Object? value) {
    if (value is! int || value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }

  @override
  String toString() => 'CodexThread($id, $cwd)';
}

/// How Codex's own record says one file changed in a turn.
///
/// Measured against 0.153.4 over the owner's 19 threads on 2026-09-08: 110
/// changes, 86 `update`, 21 `add`, 3 `delete`. A `type` this build does not know
/// reads as [unknown] rather than as a modification, because guessing the
/// weaker claim for a kind Codex adds later is still guessing.
enum CodexFileChangeKind { add, update, delete, unknown }

/// One file a `fileChange` item names, without its diff.
///
/// **The diff is deliberately dropped on the way in.** One `full` page of a
/// 23-turn thread is 15.4 MB of JSON, of which 127 KB is diff text; keeping
/// every hunk to draw a list of 58 paths is the cost this type exists to avoid.
/// Anyone who wants the patch has the working tree and the Changes panel.
class CodexFileChange {
  const CodexFileChange({required this.path, required this.kind, this.movedTo});

  /// The change, or `null` when it names no path to file it under.
  static CodexFileChange? fromJson(Object? row) {
    if (row is! Map) return null;
    final path = row['path'];
    if (path is! String || path.isEmpty) return null;
    final kind = row['kind'];
    final moved = kind is Map ? kind['move_path'] : null;
    return CodexFileChange(
      path: path,
      kind: switch (kind is Map ? kind['type'] : null) {
        'add' => CodexFileChangeKind.add,
        'update' => CodexFileChangeKind.update,
        'delete' => CodexFileChangeKind.delete,
        _ => CodexFileChangeKind.unknown,
      },
      movedTo: moved is String && moved.isNotEmpty ? moved : null,
    );
  }

  /// Absolute, and in **Codex's** spelling — a POSIX path inside the
  /// distribution for a WSL install, which this host cannot open as written.
  /// `PathTranslator` is the one place that changes that.
  final String path;

  final CodexFileChangeKind kind;

  /// Where the file moved to, for an `update` carrying a `move_path`. Null in
  /// all 110 changes measured, so the branch is pinned by a test rather than by
  /// a sighting.
  final String? movedTo;

  @override
  String toString() => 'CodexFileChange(${kind.name} $path)';
}
