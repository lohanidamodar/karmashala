import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_flutter_apps/projects.dart';
import 'package:karmashala_git/git.dart';

import '../../agents/data/agents_data.dart';
import '../../git/data/git_data.dart';

/// What a folder turned out to hold, read before it becomes a project (UI
/// overhaul spec §5). Each part is null when it could not be read, which the
/// dialog says rather than guessing.
class ProjectSourcePreview {
  const ProjectSourcePreview({
    required this.git,
    this.branch,
    this.remote,
    this.app,
    this.appNote,
    this.conversations,
  });

  final GitPresence git;
  final String? branch;
  final String? remote;

  /// The app kind, or null when none was found or it could not be looked for.
  final ProjectReading? app;

  /// Why [app] is null, when the reader said.
  final String? appNote;

  /// Earlier conversations the agents' stores hold at or under the folder, by
  /// agent display name; null when the stores could not be read.
  final Map<String, int>? conversations;

  int get conversationCount =>
      conversations?.values.fold<int>(0, (sum, n) => sum + n) ?? 0;
}

/// Reads a [ProjectSourcePreview] with the detectors the app already has: git
/// at the server, the app-kind scanner on this machine's runner (an SSH box is
/// refused in words), and the server's store scan for conversations.
class ProjectSourcePreviewReader {
  ProjectSourcePreviewReader(this._git, this._runners, this._agentWork);

  final GitData _git;
  final CommandRunnerFactory _runners;
  final AgentWorkData _agentWork;

  /// One store scan per reader: it walks every store, so typing a path must
  /// not repeat it on each pause.
  Future<List<DetectedProject>>? _stores;

  Future<ProjectSourcePreview> read(
    EnvironmentPath root,
    ExecutionEnvironment environment,
  ) async {
    final results = await Future.wait<Object?>([
      _gitFacts(root),
      _app(root, environment),
      _conversations(root, environment),
    ]);
    final git = results[0]! as (GitPresence, String?, String?);
    final app = results[1]! as (ProjectReading?, String?);
    return ProjectSourcePreview(
      git: git.$1,
      branch: git.$2,
      remote: git.$3,
      app: app.$1,
      appNote: app.$2,
      conversations: results[2] as Map<String, int>?,
    );
  }

  Future<(GitPresence, String?, String?)> _gitFacts(
    EnvironmentPath root,
  ) async {
    final presence = await _git.presenceOf(root);
    if (presence == GitPresence.notARepository) return (presence, null, null);
    try {
      final branch = await _git.currentBranch(root);
      final remote = await _git.remoteUrl(root);
      return (GitPresence.repository, branch, remote);
    } on Object {
      return (presence, null, null);
    }
  }

  Future<(ProjectReading?, String?)> _app(
    EnvironmentPath root,
    ExecutionEnvironment environment,
  ) async {
    try {
      final scanned = await ProjectScanner(
        runner: _runners.forEnvironment(environment),
        kind: environment.kind,
      ).readAt(root);
      return (scanned.project, scanned.note);
    } on Object catch (error) {
      return (null, 'Not looked for here: $error');
    }
  }

  Future<Map<String, int>?> _conversations(
    EnvironmentPath root,
    ExecutionEnvironment environment,
  ) async {
    final List<DetectedProject> stores;
    try {
      stores = await (_stores ??= _agentWork.scanImports());
    } on Object {
      _stores = null;
      return null;
    }
    // The merger's own key, so a WSL /mnt/c path and its Windows spelling meet.
    final (key, _) = canonicalProjectPath(root, environment);
    final counts = <String, int>{};
    for (final project in stores) {
      final k = project.canonicalKey;
      if (k != key && !k.startsWith('$key\\') && !k.startsWith('$key/')) {
        continue;
      }
      for (final session in project.sessions) {
        final name = AgentRegistry.builtIn.displayNameFor(session.cli);
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    return counts;
  }
}
