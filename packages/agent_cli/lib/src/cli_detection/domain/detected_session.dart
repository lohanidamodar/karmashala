import '../../environments/environment_path.dart';

/// A coding-agent session discovered on disk from a CLI's own store (Claude
/// Code or Codex). Ported and adapted from the reference Karmashala CLI.
class DetectedSession {
  const DetectedSession({
    required this.cli,
    required this.sessionId,
    required this.cwd,
    required this.filePath,
    required this.storeHome,
    this.title,
    this.preview = '',
    this.startedAt,
    this.modifiedAt,
    this.entrypoint,
  });

  /// The `AgentDescriptor.id` of the CLI that produced this session
  /// (`claudeCode` or `codex`).
  final String cli;

  /// The CLI's session identifier (Claude: file name; Codex: rollout id).
  final String sessionId;

  /// Working directory the session ran in, bound to its environment.
  final EnvironmentPath cwd;

  /// The session file's path, in a form the app can read/write directly
  /// (Windows-native, or a `\\wsl.localhost\…` UNC path for WSL stores).
  final String filePath;

  /// The CLI store home (the `.claude` or `.codex` directory) the file lives in
  /// — used to locate index files for rename/delete.
  final String storeHome;

  /// User-set or AI title (Claude `custom-title`/`ai-title`; Codex thread name).
  final String? title;

  /// First user message preview.
  final String preview;

  /// When the CLI says this conversation **began**, or `null` for a store that
  /// does not record it.
  ///
  /// Different from [modifiedAt] in the one way that matters to
  /// `LaunchedSessionAttributionService`: a conversation's start is fixed, so it
  /// can be compared against the moment a session row was written, while its
  /// last-modified time is "a moment ago" for everything still being typed in.
  /// Matching a launched Codex row on mtime would therefore accept any live
  /// conversation in the directory, including one running in somebody else's
  /// terminal window.
  ///
  /// Null for Claude Code (which is told our id at launch and needs no
  /// inference) and for Antigravity (whose store yields identity without a
  /// start, and whose rows `AntigravitySessionAttributionService` owns).
  final DateTime? startedAt;

  final DateTime? modifiedAt;

  /// Claude's launch entrypoint (`cli`, `claude-vscode`, `sdk-cli`, …). Codex
  /// records none.
  final String? entrypoint;

  String get environmentId => cwd.environmentId;

  /// Whether this is an SDK-spawned subagent session. Claude Code hides these
  /// from `claude --resume`; we surface them nested under their project.
  bool get isSubagent =>
      entrypoint == 'sdk-cli' ||
      entrypoint == 'sdk-ts' ||
      entrypoint == 'sdk-py';

  /// Best display label.
  String get displayTitle {
    final t = title;
    if (t != null && t.trim().isNotEmpty) return t;
    if (preview.trim().isNotEmpty) return preview;
    return '(empty session)';
  }

  @override
  bool operator ==(Object other) =>
      other is DetectedSession &&
      other.cli == cli &&
      other.sessionId == sessionId &&
      other.filePath == filePath;

  @override
  int get hashCode => Object.hash(cli, sessionId, filePath);

  @override
  String toString() => 'DetectedSession($cli, $sessionId, ${cwd.path})';
}
