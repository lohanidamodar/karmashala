import 'project_descriptor.dart';
import 'project_kind.dart';

/// The `agentId` a project build pane is opened under — namespaced like
/// `kFlutterLoopAgentId`, so a restored pane under it replays nothing.
const String kProjectBuildAgentId = 'karmashala:project-build';

/// What is in the way of a build, before anything is spawned. Each value is a
/// different thing to *do*, which is why they are not one "not ready".
enum ProjectBuildProblem {
  /// The resolver could not say where this checkout's commands run.
  environmentUnresolved,

  /// Nothing at that directory answers to any kind's markers.
  notAProject,

  /// The kind is detected and has no descriptor: detection and nothing else.
  noDescriptor,

  /// The descriptor has no spec for that target at all.
  targetUnknown,

  /// The spec exists and every field of it is unchecked. This is the iOS case,
  /// and the refusal carries the descriptor's own sentence.
  targetUnchecked,

  /// No `gradlew` in the project. Never a global gradle instead.
  noWrapper,

  /// A Gradle build whose settings script includes no module applying
  /// `com.android.application`.
  noApplicationModule,

  /// A build for this project and target is already going.
  alreadyRunning,

  /// There is no terminal in this window, so nothing could be run visibly.
  noPane,
}

/// One sentence naming the problem **and the fix**, or nothing in the way.
class ProjectBuildPreflight {
  const ProjectBuildPreflight.clear() : problem = null, reason = '';

  const ProjectBuildPreflight.blocked(
    ProjectBuildProblem this.problem,
    this.reason,
  );

  final ProjectBuildProblem? problem;

  /// Empty when clear. Names the fix, never only the fault.
  final String reason;

  bool get isClear => problem == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': isClear,
    if (problem != null) 'problem': problem!.name,
    if (reason.isNotEmpty) 'reason': reason,
  };

  @override
  String toString() => isClear ? 'preflight: clear' : 'preflight: $reason';
}

/// Whether the process in a build's pane is still going — and the third
/// answer, for a pane the terminal no longer knows.
enum ProjectBuildLiveness { running, finished, unknown }

/// One build the app started, and everything known about it. The pane is the
/// process, as for `FlutterCommandRun`: no second handle, and nothing polls.
class ProjectBuildRun {
  const ProjectBuildRun({
    required this.paneId,
    required this.kind,
    required this.target,
    required this.projectDirectory,
    required this.environmentId,
    required this.command,
    required this.artifactDirectory,
    required this.startedAt,
    this.module,
    this.expectedArtifact,
    this.endedAt,
    this.exitCode,
  });

  /// The pane, and the run's identity. One build, one pane.
  final String paneId;

  final ProjectKind kind;

  final ProjectTarget target;

  final String projectDirectory;

  final String environmentId;

  /// The argv actually spelled, so a reader sees the wrapper that was chosen.
  final List<String> command;

  /// Where the artifact is expected, relative to the project, forward-slashed.
  final String artifactDirectory;

  /// The file name the descriptor expects. The build's own
  /// `output-metadata.json` overrules it, which is why this is only expected.
  final String? expectedArtifact;

  final String? module;

  final DateTime startedAt;

  final DateTime? endedAt;

  /// Null while running **and** when the exit was never observed.
  final int? exitCode;

  ProjectBuildRun copyWith({DateTime? endedAt, int? exitCode}) =>
      ProjectBuildRun(
        paneId: paneId,
        kind: kind,
        target: target,
        projectDirectory: projectDirectory,
        environmentId: environmentId,
        command: command,
        artifactDirectory: artifactDirectory,
        expectedArtifact: expectedArtifact,
        module: module,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        exitCode: exitCode ?? this.exitCode,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'paneId': paneId,
    'kind': kind.name,
    'target': target.name,
    'projectDirectory': projectDirectory,
    'environmentId': environmentId,
    'command': command,
    'artifactDirectory': artifactDirectory,
    if (expectedArtifact != null) 'expectedArtifact': expectedArtifact,
    if (module != null) 'module': module,
    'startedAt': startedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
    if (exitCode != null) 'exitCode': exitCode,
  };
}
