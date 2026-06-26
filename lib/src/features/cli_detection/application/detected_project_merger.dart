import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';

/// Merges detected sessions into projects keyed by a **canonical path**, so the
/// same folder seen via different CLIs and environments (e.g. Codex
/// `/mnt/g/dev/x` and Claude `G:\dev\x`) collapses into one project. WSL
/// `/mnt/<drive>` paths are folded to their Windows-drive form; everything is
/// compared case-insensitively. Real sessions and SDK-spawned subagents are
/// separated.
List<DetectedProject> mergeDetectedProjects(
  List<DetectedSession> sessions,
  Map<String, ExecutionEnvironment> environmentsById, {
  PathTranslator translator = const PathTranslator(),
}) {
  final groups = <String, _Group>{};

  for (final session in sessions) {
    final env = environmentsById[session.environmentId];
    final (key, display) = _canonical(session, env, translator);
    final group = groups.putIfAbsent(key, () => _Group(key, display));
    if (session.isSubagent) {
      group.subagents.add(session);
    } else {
      group.sessions.add(session);
    }
  }

  int byModifiedDesc(DetectedSession a, DetectedSession b) =>
      (b.modifiedAt ?? DateTime(0)).compareTo(a.modifiedAt ?? DateTime(0));

  final projects = groups.values.map((g) {
    g.sessions.sort(byModifiedDesc);
    g.subagents.sort(byModifiedDesc);
    return DetectedProject(
      canonicalKey: g.key,
      displayPath: g.display,
      sessions: g.sessions,
      subagentSessions: g.subagents,
    );
  }).toList();

  projects.sort(
    (a, b) => (b.lastActiveAt ?? DateTime(0)).compareTo(
      a.lastActiveAt ?? DateTime(0),
    ),
  );
  return projects;
}

(String, String) _canonical(
  DetectedSession session,
  ExecutionEnvironment? env,
  PathTranslator translator,
) {
  final path = session.cwd.path;
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');

  if (env != null && env.kind == EnvironmentKind.windowsNative) {
    final win = trimmed.replaceAll('/', r'\');
    return (win.toLowerCase(), win);
  }

  if (env != null && env.kind == EnvironmentKind.wsl) {
    // Fold WSL drive mounts to their Windows form so they merge with native
    // Windows sessions for the same folder.
    if (RegExp(r'^/mnt/[a-zA-Z](/|$)').hasMatch(trimmed)) {
      try {
        final win = translator.wslMountToWindowsDrive(trimmed);
        return (win.toLowerCase(), win);
      } on PathTranslationException {
        // fall through
      }
    }
    // WSL-native path: scope the key to the environment.
    return ('${session.environmentId}:${trimmed.toLowerCase()}', trimmed);
  }

  // Unknown environment: scope to the environment id.
  return ('${session.environmentId}:${trimmed.toLowerCase()}', trimmed);
}

class _Group {
  _Group(this.key, this.display);
  final String key;
  final String display;
  final List<DetectedSession> sessions = [];
  final List<DetectedSession> subagents = [];
}
