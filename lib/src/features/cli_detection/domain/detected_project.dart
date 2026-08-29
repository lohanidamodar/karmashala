import 'detected_session.dart';

/// A project discovered from CLI session stores: one folder, merged across CLIs
/// (Claude Code and Codex) and environments (Windows and WSL) pointing at the
/// same path. Top-level [sessions] are real user sessions; [subagentSessions]
/// are SDK-spawned subagents shown nested under the project.
class DetectedProject {
  const DetectedProject({
    required this.canonicalKey,
    required this.displayPath,
    required this.sessions,
    required this.subagentSessions,
  });

  /// Normalized merge key (case-insensitive; WSL `/mnt/<drive>` folded to its
  /// Windows-drive form).
  final String canonicalKey;

  /// Human-readable path (the canonical form).
  final String displayPath;

  /// Real (non-subagent) sessions, most-recent first.
  final List<DetectedSession> sessions;

  /// SDK-spawned subagent sessions, most-recent first.
  final List<DetectedSession> subagentSessions;

  String get name {
    final cleaned = displayPath.replaceAll(RegExp(r'[\\/]+$'), '');
    final parts = cleaned.split(RegExp(r'[\\/]'));
    return parts.isEmpty || parts.last.isEmpty ? cleaned : parts.last;
  }

  int countFor(String cli) => sessions.where((s) => s.cli == cli).length;

  Set<String> get environmentIds => {
    for (final s in [...sessions, ...subagentSessions]) s.environmentId,
  };

  DateTime? get lastActiveAt {
    DateTime? latest;
    for (final s in [...sessions, ...subagentSessions]) {
      final at = s.modifiedAt;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }
}
