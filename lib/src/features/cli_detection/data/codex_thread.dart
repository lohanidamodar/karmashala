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
