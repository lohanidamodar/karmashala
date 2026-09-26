import '../../environments/environment_kind.dart';
import '../../environments/environment_path.dart';
import '../../environments/execution_environment.dart';
import '../../process/path_translator.dart';
import 'detected_project.dart';
import 'detected_session.dart';

/// Merges detected sessions into projects keyed by a canonical path, so the
/// same folder seen through different CLIs and environments is one project.
List<DetectedProject> mergeDetectedProjects(
  List<DetectedSession> sessions,
  Map<String, ExecutionEnvironment> environmentsById, {
  PathTranslator translator = const PathTranslator(),
}) {
  final groups = <String, _Group>{};

  for (final session in sessions) {
    if (session.cwd.path.trim().isEmpty) continue;
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
  final (key, display) = canonicalProjectPath(session.cwd, env, translator);
  return (key, display);
}

/// The canonical `(mergeKey, displayPath)` for a path in [env] — the same
/// normalization the merger uses, exposed for other features.
(String, String) canonicalProjectPath(
  EnvironmentPath path,
  ExecutionEnvironment? env, [
  PathTranslator translator = const PathTranslator(),
]) {
  final trimmed = path.path.replaceAll(RegExp(r'[\\/]+$'), '');

  if (env != null && env.kind == EnvironmentKind.windowsNative) {
    final win = trimmed.replaceAll('/', r'\');
    return (win.toLowerCase(), win);
  }

  if (env != null && env.kind == EnvironmentKind.wsl) {
    if (RegExp(r'^/mnt/[a-zA-Z](/|$)').hasMatch(trimmed)) {
      try {
        final win = translator.wslMountToWindowsDrive(trimmed);
        return (win.toLowerCase(), win);
      } on PathTranslationException {
        // fall through
      }
    }
    return ('${path.environmentId}:${trimmed.toLowerCase()}', trimmed);
  }

  return ('${path.environmentId}:${trimmed.toLowerCase()}', trimmed);
}

class _Group {
  _Group(this.key, this.display);
  final String key;
  final String display;
  final List<DetectedSession> sessions = [];
  final List<DetectedSession> subagents = [];
}
