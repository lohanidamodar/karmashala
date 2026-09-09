import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../flutter_apps/application/flutter_sdk_readings.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/project_scanner.dart';
import '../domain/apk_output_metadata.dart';
import '../domain/project_build.dart';
import '../domain/project_descriptor.dart';
import '../domain/project_detection.dart';

/// How many of a build pane's bottom rows come back with an answer.
const int kProjectBuildLogRows = 80;

/// Everything a preflight established, so the caller does not ask again.
typedef ProjectBuildReadiness = ({
  ProjectBuildPreflight preflight,
  ExecutionEnvironment? environment,
  ProjectReading? project,
  ProjectBuildSpec? spec,
  List<String> argv,
});

/// What a start attempt did: the build it opened, or the line saying why not.
typedef ProjectBuildOutcome = ({
  ProjectBuildPreflight preflight,
  ProjectBuildRun? run,
});

/// What is on disk where the artifact was meant to land, with its age.
typedef ProjectArtifactReading = ({
  /// The artifact's absolute path in that environment's own spelling, or null
  /// when there is nothing there.
  String? path,

  /// From the build's own `output-metadata.json`. Null when it has not been
  /// written, which is "not yet" rather than "there is none".
  String? applicationId,

  /// What was read and what it said, so the caller can disagree.
  String note,
});

/// The build half of a project's lifecycle: detect the kind, run the kind's
/// own build command in a visible pane, and read back what it produced.
///
/// **Descriptor-driven, so a second framework is a row and not a feature.**
/// Nothing below knows the word "Gradle" except where it has to spell a
/// wrapper's file name; the command, the artifact and the application id all
/// come off `ProjectDescriptor`, and the kind that has none is refused in
/// words.
///
/// **It never installs or launches.** The fourteen `device_*` tools are
/// framework-agnostic already and are the whole device surface; a second path
/// from here would be the duplicate the backlog item refuses. What this
/// returns is the artifact path and the application id — the two arguments
/// `device_install_app` and `device_launch_app` take.
class ProjectBuildController extends Notifier<List<ProjectBuildRun>> {
  @override
  List<ProjectBuildRun> build() => const <ProjectBuildRun>[];

  DateTime get _now => ref.read(clockProvider).nowUtc();

  List<ProjectBuildRun> get runs => state;

  ProjectBuildRun? byPane(String paneId) {
    for (final run in state) {
      if (run.paneId == paneId) return run;
    }
    return null;
  }

  /// What kind of project is at [project], and the specific reason when it is
  /// none.
  ///
  /// Costs a few file reads in that environment and nothing else. Runs when
  /// somebody asks — never on a rebuild and never on a tick (§19).
  Future<({ProjectReading? project, String? note})> scan(
    EnvironmentPath project,
  ) async {
    final resolution = ref.read(environmentResolverProvider).resolveFor(project);
    final environment = resolution.environment;
    if (environment == null) {
      return (project: null, note: resolution.reason);
    }
    return _scannerFor(environment).readAt(project);
  }

  /// Everything that has to be true before [target] can be built in
  /// [project], asked in the order that makes each refusal actionable.
  Future<ProjectBuildReadiness> readiness(
    EnvironmentPath project,
    ProjectTarget target,
  ) async {
    const empty = <String>[];
    final resolution = ref.read(environmentResolverProvider).resolveFor(project);
    final environment = resolution.environment;
    if (environment == null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.environmentUnresolved,
          '${resolution.reason}. Pick the checkout in Karmashala, or record '
              'the environment it belongs to, before building in it.',
        ),
        environment: null,
        project: null,
        spec: null,
        argv: empty,
      );
    }

    final scanner = _scannerFor(environment);
    final scanned = await scanner.readAt(project);
    final reading = scanned.project;
    if (reading == null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.notAProject,
          scanned.note ??
              '${project.path} carries no marker Karmashala knows: no '
                  'pubspec.yaml with a flutter: section, no package.json '
                  'naming react-native, no settings.gradle including a '
                  'com.android.application module, and no .xcodeproj. Nothing '
                  'was guessed at.',
        ),
        environment: environment,
        project: null,
        spec: null,
        argv: empty,
      );
    }

    final descriptor = reading.descriptor;
    if (descriptor == null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.noDescriptor,
          'This is a ${reading.kind.label} project and Karmashala can only '
              'spot it. There is no build command for that kind here, because '
              'nobody has run its toolchain from this app.',
        ),
        environment: environment,
        project: reading,
        spec: null,
        argv: empty,
      );
    }

    final spec = descriptor.buildFor(target);
    if (spec == null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.targetUnknown,
          'A ${reading.kind.label} project has no ${target.label} build in '
              'this app. Its targets are '
              '${descriptor.builds.map((b) => b.target.label).join(', ')}.',
        ),
        environment: environment,
        project: reading,
        spec: null,
        argv: empty,
      );
    }
    if (!spec.isRunnable) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.targetUnchecked,
          spec.refusal,
        ),
        environment: environment,
        project: reading,
        spec: spec,
        argv: empty,
      );
    }

    // The tool, resolved per environment. This is the one place a spec's
    // `tool` becomes a real executable, and every route through it is §17's:
    // never a bare name we hope resolves, never a global gradle.
    final String executable;
    switch (spec.tool) {
      case ProjectBuildTool.flutterSdk:
        final sdk = await ref
            .read(flutterSdkReadingsProvider.notifier)
            .readFor(environment);
        if (!sdk.isUsable) {
          return (
            preflight: ProjectBuildPreflight.blocked(
              ProjectBuildProblem.noWrapper,
              sdk.reason,
            ),
            environment: environment,
            project: reading,
            spec: spec,
            argv: empty,
          );
        }
        executable = sdk.executable!;
      case ProjectBuildTool.gradleWrapper:
        final wrapper = await _gradleWrapperIn(scanner, project, environment);
        if (wrapper == null) {
          return (
            preflight: ProjectBuildPreflight.blocked(
              ProjectBuildProblem.noWrapper,
              '${project.path} has no Gradle wrapper — no '
                  '${usesWindowsPaths(environment.kind) ? 'gradlew.bat' : 'gradlew'} '
                  'beside its settings script — so there is nothing in the '
                  'project to build with. Karmashala will not fall back to a '
                  'gradle on PATH: that would build with a different Gradle '
                  'than the project pins. Run "gradle wrapper" in it once.',
            ),
            environment: environment,
            project: reading,
            spec: spec,
            argv: empty,
          );
        }
        executable = wrapper;
      case ProjectBuildTool.xcodebuild:
      case ProjectBuildTool.packageScript:
        return (
          preflight: ProjectBuildPreflight.blocked(
            ProjectBuildProblem.targetUnchecked,
            spec.refusal.isEmpty
                ? 'Nobody here has run ${spec.tool.label}.'
                : spec.refusal,
          ),
          environment: environment,
          project: reading,
          spec: spec,
          argv: empty,
        );
    }

    // A guard on the *data*, not on detection: a spec whose command still
    // carries the placeholder has nothing to put in it. Detection never hands
    // back a native Android reading without a module, so this fires only if a
    // descriptor and a kind are ever wired up wrong.
    final module = reading.androidModule;
    final needsModule = spec.command.value!.any(
      (part) => part.contains(ProjectBuildSpec.modulePlaceholder),
    );
    if (needsModule && module == null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.noApplicationModule,
          '${project.path} includes no module applying '
              'com.android.application, so there is no app to assemble. A '
              'library-only build has nothing to install on a device.',
        ),
        environment: environment,
        project: reading,
        spec: spec,
        argv: empty,
      );
    }

    return (
      preflight: const ProjectBuildPreflight.clear(),
      environment: environment,
      project: reading,
      spec: spec,
      argv: <String>[executable, ...spec.commandFor(module: module)!],
    );
  }

  /// Builds [project] for [target] in a visible pane, in the repository's own
  /// environment.
  ///
  /// Started, not awaited — the same shape as the Flutter loop and the
  /// worktree setup hook. A cold Gradle build downloads a toolchain and has no
  /// bound; holding a tool call on it would be a hang, and running it out of
  /// sight is the failure the visible pane exists to remove.
  Future<ProjectBuildOutcome> start(
    EnvironmentPath project,
    ProjectTarget target, {
    List<String> extraArguments = const <String>[],
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
              'pane ${live.paneId}. Wait for it rather than starting a second '
              'one: two builds writing the same build/ directory is how a '
              'half-written artifact gets installed.',
        ),
        run: null,
      );
    }

    final reading = ready.project!;
    final spec = ready.spec!;
    final module = reading.androidModule;
    final artifact = spec.artifactFor(module: reading.androidModuleDirectory)!;
    final argv = <String>[...ready.argv, ...extraArguments];

    final String? paneId;
    try {
      paneId = ref.read(visibleCommandOpenerProvider)(
        VisibleCommand(
          agentId: kProjectBuildAgentId,
          argv: argv,
          directory: project,
          environment: ready.environment!,
          title: '${target.label} build · ${reading.name}',
        ),
      );
    } on Object catch (error) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.noPane,
          'The pane for "${argv.join(' ')}" could not be opened: $error',
        ),
        run: null,
      );
    }
    if (paneId == null) {
      return (
        preflight: ProjectBuildPreflight.blocked(
          ProjectBuildProblem.noPane,
          'There is no terminal in this window to run "${argv.join(' ')}" in, '
              'so it was not run. Running a build out of sight is the failure '
              'this feature exists to remove — see CLAUDE.md §17.',
        ),
        run: null,
      );
    }

    final run = ProjectBuildRun(
      paneId: paneId,
      kind: reading.kind,
      target: target,
      projectDirectory: project.path,
      environmentId: ready.environment!.id,
      command: argv,
      artifactDirectory: artifact.directory,
      expectedArtifact: artifact.fileName,
      module: module,
      startedAt: _now,
    );
    state = <ProjectBuildRun>[...state, run];
    return (preflight: const ProjectBuildPreflight.clear(), run: run);
  }

  /// What the build produced, read from the build's own record.
  ///
  /// `output-metadata.json` is the source, because it is the one answer that
  /// came from the toolchain rather than from our parse of somebody's build
  /// script — see `apk_output_metadata.dart` for the three sources that were
  /// crossed and agreed.
  Future<ProjectArtifactReading> artifactOf(ProjectBuildRun run) async {
    final environment = ref
        .read(executionEnvironmentDaoProvider)
        .getById(run.environmentId);
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
            'not produced it yet, or it failed — the pane says which.',
      );
    }
    return (
      path: scanner.absolutePathOf(directory, '${run.artifactDirectory}/$fileName'),
      applicationId: reading?.applicationId,
      note: reading == null
          ? 'Found by name. output-metadata.json is not beside it, so the '
                'application id was not read and is unknown rather than absent.'
          : 'output-metadata.json beside it names '
                '${reading.applicationId} (${reading.variantName}).',
    );
  }

  /// Whether the process in [paneId] is still going, and the honest third
  /// answer for a pane the terminal no longer knows.
  ProjectBuildLiveness livenessOf(String paneId) {
    final held = ref.read(terminalSessionsControllerProvider).liveness[paneId];
    return switch (held) {
      null => ProjectBuildLiveness.unknown,
      PaneLiveness.live => ProjectBuildLiveness.running,
      PaneLiveness.restored => ProjectBuildLiveness.unknown,
      PaneLiveness.exited => ProjectBuildLiveness.finished,
    };
  }

  /// The live build of [target] for [directory], if there is one.
  ProjectBuildRun? liveBuildFor(String directory, ProjectTarget target) {
    for (final run in state.reversed) {
      if (run.target != target) continue;
      if (!_sameDirectory(run.projectDirectory, directory)) continue;
      if (livenessOf(run.paneId) == ProjectBuildLiveness.running) return run;
    }
    return null;
  }

  /// The bottom rows of [paneId]'s buffer, or empty when the pane is gone.
  List<String> tailOf(String paneId, {int lines = kProjectBuildLogRows}) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) return const <String>[];
    return terminalTailLines(instance.terminal, lines: lines);
  }

  /// The process in [paneId] has stopped. Returns the build it belonged to
  /// with its exit code on it, or null when that pane was not one of ours.
  ProjectBuildRun? noteExit(String paneId, int? exitCode) {
    final run = byPane(paneId);
    if (run == null) return null;
    final ended = run.copyWith(endedAt: _now, exitCode: exitCode);
    _replace(ended);
    return ended;
  }

  /// Ends the process in [paneId].
  ///
  /// `endSession` rather than `closePane`: the default there detaches a live
  /// process and keeps it alive, which for a Gradle build would leave a daemon
  /// writing the artifact nobody is watching.
  Future<ProjectBuildRun?> stop(String paneId) async {
    final run = byPane(paneId);
    if (run == null) return null;
    ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
    final stopped = run.copyWith(endedAt: _now);
    _replace(stopped);
    return stopped;
  }

  void _replace(ProjectBuildRun updated) {
    state = <ProjectBuildRun>[
      for (final run in state)
        if (run.paneId == updated.paneId) updated else run,
    ];
  }

  /// The project's own wrapper, spelled the way the pane will run it, or null
  /// when the project has none.
  Future<String?> _gradleWrapperIn(
    ProjectScanner scanner,
    EnvironmentPath project,
    ExecutionEnvironment environment,
  ) async {
    final entries = await scanner.listEntries(project, '');
    if (usesWindowsPaths(environment.kind)) {
      return entries.contains('gradlew.bat') ? 'gradlew.bat' : null;
    }
    return entries.contains('gradlew') ? './gradlew' : null;
  }

  ProjectScanner _scannerFor(ExecutionEnvironment environment) => ProjectScanner(
    runner: ref.read(commandRunnerFactoryProvider).forEnvironment(environment),
    kind: environment.kind,
  );

  /// Two spellings of the same directory, compared the way the filesystem
  /// would.
  static bool _sameDirectory(String a, String b) =>
      a.replaceAll('\\', '/').toLowerCase().replaceAll(RegExp(r'/+$'), '') ==
      b.replaceAll('\\', '/').toLowerCase().replaceAll(RegExp(r'/+$'), '');
}

final projectBuildProvider =
    NotifierProvider<ProjectBuildController, List<ProjectBuildRun>>(
      ProjectBuildController.new,
    );
