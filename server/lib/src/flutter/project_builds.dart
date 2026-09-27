import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show HostedRun, HostedRunFamily, hostedRunPaneId;
import 'package:karmashala_flutter_apps/projects.dart';

import 'flutter_sdk_readings.dart';
import 'hosted_runs.dart';

/// How many of a build's bottom rows come back with an answer.
const int kProjectBuildLogRows = 80;

typedef ProjectBuildReadiness = ({
  ProjectBuildPreflight preflight,
  ExecutionEnvironment? environment,
  ProjectReading? project,
  ProjectBuildSpec? spec,
  List<String> argv,
});

typedef ProjectBuildOutcome = ({
  ProjectBuildPreflight preflight,
  ProjectBuildRun? run,
});

/// What is on disk where the artifact was meant to land.
typedef ProjectArtifactReading = ({
  String? path,
  String? applicationId,
  String note,
});

/// The build half of a project's lifecycle, run by the server as hosted runs
/// (slice 3d): detect the kind, build, read back the artifact. It never
/// installs or launches.
class ServerProjectBuilds {
  ServerProjectBuilds({
    required this.hosted,
    required this.sdk,
    required this.rows,
    this.runners = const CommandRunnerFactory(),
  });

  final HostedRuns hosted;
  final ServerFlutterSdk sdk;
  final CheckoutRows rows;
  final CommandRunnerFactory runners;

  final _runs = <String, ProjectBuildRun>{};
  final _runIds = <String, String>{};

  List<ProjectBuildRun> get runs => List.unmodifiable(_runs.values);

  ProjectBuildRun? byPane(String paneId) => _runs[paneId];

  ProjectScanner _scannerFor(ExecutionEnvironment environment) =>
      ProjectScanner(
        runner: runners.forEnvironment(environment),
        kind: environment.kind,
      );

  /// What kind of project is at [project], and why when it is none.
  Future<({ProjectReading? project, String? note})> scan(
    EnvironmentPath project,
  ) async {
    final environment = rows.environment(project.environmentId);
    if (environment == null) {
      return (
        project: null,
        note: 'The environment ${project.environmentId} is not recorded',
      );
    }
    final refused = hosted.refusalFor(environment);
    if (refused != null) return (project: null, note: refused);
    return _scannerFor(environment).readAt(project);
  }

  Future<ProjectBuildReadiness> readiness(
    EnvironmentPath project,
    ProjectTarget target,
  ) async {
    const empty = <String>[];
    ProjectBuildReadiness blocked(
      ProjectBuildProblem problem,
      String reason, {
      ExecutionEnvironment? environment,
      ProjectReading? reading,
      ProjectBuildSpec? spec,
    }) => (
      preflight: ProjectBuildPreflight.blocked(problem, reason),
      environment: environment,
      project: reading,
      spec: spec,
      argv: empty,
    );

    final environment = rows.environment(project.environmentId);
    if (environment == null) {
      return blocked(
        ProjectBuildProblem.environmentUnresolved,
        'The environment ${project.environmentId} is not recorded. Pick the '
        'checkout in Karmashala, or record the environment it belongs to, '
        'before building in it.',
      );
    }
    final refused = hosted.refusalFor(environment);
    if (refused != null) {
      return blocked(
        ProjectBuildProblem.environmentUnresolved,
        refused,
        environment: environment,
      );
    }
    final scanner = _scannerFor(environment);
    final scanned = await scanner.readAt(project);
    final reading = scanned.project;
    if (reading == null) {
      return blocked(
        ProjectBuildProblem.notAProject,
        scanned.note ??
            '${project.path} carries no marker Karmashala knows: no '
                'pubspec.yaml with a flutter: section, no package.json '
                'naming react-native, no settings.gradle including a '
                'com.android.application module, and no .xcodeproj. Nothing '
                'was guessed at.',
        environment: environment,
      );
    }
    final descriptor = reading.descriptor;
    if (descriptor == null) {
      return blocked(
        ProjectBuildProblem.noDescriptor,
        'This is a ${reading.kind.label} project and Karmashala can only '
        'spot it. There is no build command for that kind here, because '
        'nobody has run its toolchain from this app.',
        environment: environment,
        reading: reading,
      );
    }
    final spec = descriptor.buildFor(target);
    if (spec == null) {
      return blocked(
        ProjectBuildProblem.targetUnknown,
        'A ${reading.kind.label} project has no ${target.label} build in '
        'this app. Its targets are '
        '${descriptor.builds.map((b) => b.target.label).join(', ')}.',
        environment: environment,
        reading: reading,
      );
    }
    if (!spec.isRunnable) {
      return blocked(
        ProjectBuildProblem.targetUnchecked,
        spec.refusal,
        environment: environment,
        reading: reading,
        spec: spec,
      );
    }
    final String executable;
    switch (spec.tool) {
      case ProjectBuildTool.flutterSdk:
        final found = await sdk.readFor(environment);
        if (!found.isUsable) {
          return blocked(
            ProjectBuildProblem.noWrapper,
            found.reason,
            environment: environment,
            reading: reading,
            spec: spec,
          );
        }
        executable = found.executable!;
      case ProjectBuildTool.gradleWrapper:
        final entries = await scanner.listEntries(project, '');
        final windows = usesWindowsPaths(environment.kind);
        final wrapper = windows
            ? (entries.contains('gradlew.bat') ? 'gradlew.bat' : null)
            : (entries.contains('gradlew') ? './gradlew' : null);
        if (wrapper == null) {
          return blocked(
            ProjectBuildProblem.noWrapper,
            '${project.path} has no Gradle wrapper — no '
            '${windows ? 'gradlew.bat' : 'gradlew'} '
            'beside its settings script — so there is nothing in the '
            'project to build with. Karmashala will not fall back to a '
            'gradle on PATH: that would build with a different Gradle '
            'than the project pins. Run "gradle wrapper" in it once.',
            environment: environment,
            reading: reading,
            spec: spec,
          );
        }
        executable = wrapper;
      case ProjectBuildTool.xcodebuild:
      case ProjectBuildTool.packageScript:
        return blocked(
          ProjectBuildProblem.targetUnchecked,
          spec.refusal.isEmpty
              ? 'Nobody here has run ${spec.tool.label}.'
              : spec.refusal,
          environment: environment,
          reading: reading,
          spec: spec,
        );
    }
    final module = reading.androidModule;
    final needsModule = spec.command.value!.any(
      (part) => part.contains(ProjectBuildSpec.modulePlaceholder),
    );
    if (needsModule && module == null) {
      return blocked(
        ProjectBuildProblem.noApplicationModule,
        '${project.path} includes no module applying '
        'com.android.application, so there is no app to assemble. A '
        'library-only build has nothing to install on a device.',
        environment: environment,
        reading: reading,
        spec: spec,
      );
    }
    return (
      preflight: const ProjectBuildPreflight.clear(),
      environment: environment,
      project: reading,
      spec: spec,
      argv: [
        executable,
        ...spec.commandFor(module: module)!,
      ],
    );
  }

  /// Builds [project] for [target] as a hosted run: started, not awaited.
  Future<ProjectBuildOutcome> start(
    EnvironmentPath project,
    ProjectTarget target, {
    List<String> extraArguments = const [],
  }) async {
    final ready = await readiness(project, target);
    if (!ready.preflight.isClear) {
      return (preflight: ready.preflight, run: null);
    }
    final live = liveBuildFor(project.path, target);
    if (live != null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.alreadyRunning,
          'A ${target.label} build for ${project.path} is already running in '
          'session ${live.paneId}. Wait for it rather than starting a second '
          'one: two builds writing the same build/ directory is how a '
          'half-written artifact gets installed.',
        ),
        run: null,
      );
    }
    final reading = ready.project!;
    final spec = ready.spec!;
    final artifact = spec.artifactFor(module: reading.androidModuleDirectory)!;
    final argv = [...ready.argv, ...extraArguments];
    final HostedRun hostedRun;
    try {
      hostedRun = hosted.start(
        argv: argv,
        directory: project,
        environment: ready.environment!,
        title: '${target.label} build · ${reading.name}',
        family: HostedRunFamily.build,
        onEnded: _noteExit,
      );
    } on HostedRunRefused catch (refused) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.noPane,
          refused.message,
        ),
        run: null,
      );
    }
    final paneId = hostedRunPaneId(hostedRun.runId);
    final run = ProjectBuildRun(
      paneId: paneId,
      kind: reading.kind,
      target: target,
      projectDirectory: project.path,
      environmentId: ready.environment!.id,
      command: argv,
      artifactDirectory: artifact.directory,
      expectedArtifact: artifact.fileName,
      module: reading.androidModule,
      startedAt: hostedRun.startedAt,
    );
    _runs[paneId] = run;
    _runIds[paneId] = hostedRun.runId;
    return (preflight: const ProjectBuildPreflight.clear(), run: run);
  }

  void _noteExit(HostedRun ended) {
    final paneId = hostedRunPaneId(ended.runId);
    final run = _runs[paneId];
    if (run == null) return;
    _runs[paneId] = run.copyWith(
      endedAt: ended.endedAt,
      exitCode: ended.exitCode,
    );
  }

  /// What the build produced, from `output-metadata.json`.
  Future<ProjectArtifactReading> artifactOf(ProjectBuildRun run) async {
    final environment = rows.environment(run.environmentId);
    if (environment == null) {
      return (
        path: null,
        applicationId: null,
        note:
            'The environment this was built in is no longer recorded, so '
            'nothing was looked for. That is a blind spot, not an absence.',
      );
    }
    final scanner = _scannerFor(environment);
    final directory = EnvironmentPath(
      environmentId: environment.id,
      path: run.projectDirectory,
    );
    final metadata = await scanner.readFile(
      directory,
      '${run.artifactDirectory}/output-metadata.json',
    );
    final reading = metadata == null ? null : readApkOutputMetadata(metadata);
    final fileName = reading?.outputFile ?? run.expectedArtifact;
    if (fileName == null) {
      return (
        path: null,
        applicationId: null,
        note:
            'No output-metadata.json under ${run.artifactDirectory} yet, and '
            'the descriptor names no file. Nothing has been built here.',
      );
    }
    final entries = await scanner.listEntries(directory, run.artifactDirectory);
    if (!entries.contains(fileName)) {
      return (
        path: null,
        applicationId: reading?.applicationId,
        note:
            '${run.artifactDirectory}/$fileName is not there. The build has '
            'not produced it yet, or it failed — its session says which.',
      );
    }
    return (
      path: scanner.absolutePathOf(
        directory,
        '${run.artifactDirectory}/$fileName',
      ),
      applicationId: reading?.applicationId,
      note: reading == null
          ? 'Found by name. output-metadata.json is not beside it, so the '
                'application id was not read and is unknown rather than absent.'
          : 'output-metadata.json beside it names '
                '${reading.applicationId} (${reading.variantName}).',
    );
  }

  ProjectBuildLiveness livenessOf(String paneId) {
    final runId = _runIds[paneId];
    if (runId == null) return ProjectBuildLiveness.unknown;
    return switch (hosted.livenessOf(runId)) {
      HostedRunLiveness.running => ProjectBuildLiveness.running,
      HostedRunLiveness.finished => ProjectBuildLiveness.finished,
      HostedRunLiveness.unknown => ProjectBuildLiveness.unknown,
    };
  }

  ProjectBuildRun? liveBuildFor(String directory, ProjectTarget target) {
    for (final run in _runs.values.toList().reversed) {
      if (run.target != target) continue;
      if (!_sameDirectory(run.projectDirectory, directory)) continue;
      if (livenessOf(run.paneId) == ProjectBuildLiveness.running) return run;
    }
    return null;
  }

  List<String> tailOf(String paneId, {int lines = kProjectBuildLogRows}) {
    final runId = _runIds[paneId];
    return runId == null ? const [] : hosted.tailOf(runId, lines: lines);
  }

  /// Ends the build — stopped, not detached, so no Gradle daemon writes on.
  Future<ProjectBuildRun?> stop(String paneId) async {
    final runId = _runIds[paneId];
    if (runId == null) return null;
    await hosted.stop(runId);
    final run = _runs[paneId];
    if (run != null && run.endedAt == null) {
      _runs[paneId] = run.copyWith(endedAt: DateTime.now().toUtc());
    }
    return _runs[paneId];
  }

  static bool _sameDirectory(String a, String b) =>
      a.replaceAll('\\', '/').toLowerCase().replaceAll(RegExp(r'/+$'), '') ==
      b.replaceAll('\\', '/').toLowerCase().replaceAll(RegExp(r'/+$'), '');
}
