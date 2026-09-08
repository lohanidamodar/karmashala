import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/flutter_project_scanner.dart';
import '../domain/flutter_command_run.dart';
import '../domain/flutter_preflight.dart';
import '../domain/flutter_project.dart';
import '../domain/flutter_sdk.dart';
import 'flutter_sdk_readings.dart';

/// Everything a preflight established, so the caller that acts on it does not
/// ask the same three questions again.
typedef FlutterReadiness = ({
  FlutterPreflight preflight,
  ExecutionEnvironment? environment,
  FlutterSdkReading? sdk,
  FlutterProject? project,
});

/// What a start attempt did: the run it opened, or the line saying why not.
typedef FlutterLoopOutcome = ({FlutterPreflight preflight, FlutterCommandRun? run});

/// One owned lifecycle for a Flutter project: where its commands run, whether
/// there is an SDK to run them with, and the visible panes they run in.
///
/// **Every `flutter` line goes through the resolver.** Not one of them is a
/// bare command or a guessed shell: `ExecutionEnvironmentResolver` says which
/// environment, `FlutterSdkReadings` says which binary in it, and
/// `visibleCommandOpenerProvider` opens the pane with the WSL distribution or
/// the SSH host attached. That chain is CLAUDE.md §17, and a refusal anywhere
/// along it is the preflight line rather than a silent fallback.
///
/// **Nothing polls.** A run's state is its pane's liveness, read when asked,
/// with the run's own [FlutterCommandRun.startedAt] as its age.
class FlutterLoopController extends Notifier<List<FlutterCommandRun>> {
  @override
  List<FlutterCommandRun> build() => const <FlutterCommandRun>[];

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// The runs this app started, newest last.
  List<FlutterCommandRun> get runs => state;

  /// The run in [paneId], or null.
  FlutterCommandRun? byPane(String paneId) {
    for (final run in state) {
      if (run.paneId == paneId) return run;
    }
    return null;
  }

  /// The live run of [kind] for [directory], if there is one.
  ///
  /// "Live" is the pane's own answer, taken now. A run whose pane has exited
  /// is history and does not stand in the way of the next one.
  FlutterCommandRun? liveRunFor(String directory, FlutterCommandKind kind) {
    for (final run in state.reversed) {
      if (run.kind != kind) continue;
      if (!_sameDirectory(run.projectDirectory, directory)) continue;
      if (livenessOf(run.paneId) == FlutterRunLiveness.running) return run;
    }
    return null;
  }

  /// Whether the process in [paneId] is still going, and the honest third
  /// answer for a pane the terminal no longer knows.
  FlutterRunLiveness livenessOf(String paneId) {
    final held = ref.read(terminalSessionsControllerProvider).liveness[paneId];
    return switch (held) {
      null => FlutterRunLiveness.unknown,
      PaneLiveness.live => FlutterRunLiveness.running,
      PaneLiveness.restored => FlutterRunLiveness.unknown,
      PaneLiveness.exited => FlutterRunLiveness.finished,
    };
  }

  /// Everything that has to be true before [kind] can run in [project], asked
  /// in the order that makes each refusal actionable.
  Future<FlutterReadiness> readiness(
    EnvironmentPath project, {
    required FlutterCommandKind kind,
  }) async {
    final resolution = ref.read(environmentResolverProvider).resolveFor(project);
    final environment = resolution.environment;
    if (environment == null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.environmentUnresolved,
          '${resolution.reason}. Pick the checkout in Karmashala, or record '
              'the environment it belongs to, before running Flutter in it.',
        ),
        environment: null,
        sdk: null,
        project: null,
      );
    }

    final sdk = await ref
        .read(flutterSdkReadingsProvider.notifier)
        .readFor(environment);
    if (!sdk.isUsable) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.noSdk,
          sdk.reason,
        ),
        environment: environment,
        sdk: sdk,
        project: null,
      );
    }

    final scanner = _scannerFor(environment);
    final found = await scanner.projectAt(project);
    if (found == null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.notAFlutterProject,
          '${project.path} has no pubspec.yaml with a flutter: key, so there '
              'is no Flutter project there to ${kind.label}. list_checkouts '
              'names the checkouts this workspace knows.',
        ),
        environment: environment,
        sdk: sdk,
        project: null,
      );
    }

    if (kind == FlutterCommandKind.run && !found.isRunnable) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.notRunnable,
          '${found.name} depends on the Flutter SDK but has no top-level '
              'flutter: section, so it is a package or a plugin rather than an '
              'app: there is no entrypoint for flutter run. Run its example, '
              'or the app that depends on it.',
        ),
        environment: environment,
        sdk: sdk,
        project: found,
      );
    }

    // `pub get` is the one command that is allowed to run without packages —
    // it is what produces them.
    if (kind != FlutterCommandKind.pubGet) {
      final packages = await scanner.hasPackageConfig(project);
      if (packages == false) {
        return (
          preflight: FlutterPreflight.blocked(
            FlutterPreflightProblem.noPackages,
            '${found.name} has no .dart_tool/package_config.json, so nothing '
                'has resolved its dependencies yet. Run flutter_run with '
                'action "pubGet" first; a fresh worktree always needs it.',
          ),
          environment: environment,
          sdk: sdk,
          project: found,
        );
      }
      // A `null` is "could not be established" and is deliberately **not** a
      // block: refusing to run because we failed to look would stop a working
      // checkout over our own blind spot (§19).
    }

    return (
      preflight: const FlutterPreflight.clear(),
      environment: environment,
      sdk: sdk,
      project: found,
    );
  }

  /// Resolves this project's dependencies, in a visible pane, in the
  /// repository's own environment.
  ///
  /// The same shape as the worktree setup hook and through the same opener:
  /// started, not awaited. `pub get` on a cold cache has no bound, and holding
  /// a tool call on it would be a hang; what the caller gets is the pane from
  /// the moment it opens, and the exit code when the process stops.
  Future<FlutterLoopOutcome> pubGet(EnvironmentPath project) async {
    final ready = await readiness(project, kind: FlutterCommandKind.pubGet);
    if (!ready.preflight.isClear) {
      return (preflight: ready.preflight, run: null);
    }
    final live = liveRunFor(project.path, FlutterCommandKind.pubGet);
    if (live != null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.alreadyRunning,
          'A pub get for ${project.path} is already running in pane '
              '${live.paneId}. Wait for it rather than starting a second one: '
              'two writing the same .dart_tool is how a package cache is '
              'corrupted.',
        ),
        run: null,
      );
    }
    return _start(
      kind: FlutterCommandKind.pubGet,
      project: project,
      environment: ready.environment!,
      sdk: ready.sdk!,
      title: 'pub get · ${ready.project!.name}',
    );
  }

  /// Opens the pane and records the run, or says there was nowhere to open one.
  Future<FlutterLoopOutcome> _start({
    required FlutterCommandKind kind,
    required EnvironmentPath project,
    required ExecutionEnvironment environment,
    required FlutterSdkReading sdk,
    required String title,
    List<String> extraArguments = const <String>[],
    String? deviceId,
    String? vmServiceOutFile,
  }) async {
    final argv = <String>[
      sdk.executable!,
      ...kind.arguments,
      ...extraArguments,
    ];
    final String? paneId;
    try {
      paneId = ref.read(visibleCommandOpenerProvider)(
        VisibleCommand(
          agentId: kFlutterLoopAgentId,
          argv: argv,
          directory: project,
          environment: environment,
          title: title,
        ),
      );
    } on Object catch (error) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.noPane,
          'The pane for "${argv.join(' ')}" could not be opened: $error',
        ),
        run: null,
      );
    }
    if (paneId == null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.noPane,
          'There is no terminal in this window to run "${argv.join(' ')}" in, '
              'so it was not run. Running it out of sight is the failure this '
              'feature exists to remove — see CLAUDE.md §17.',
        ),
        run: null,
      );
    }
    final run = FlutterCommandRun(
      paneId: paneId,
      kind: kind,
      projectDirectory: project.path,
      environmentId: environment.id,
      command: argv,
      startedAt: _now,
      deviceId: deviceId,
      vmServiceOutFile: vmServiceOutFile,
    );
    state = <FlutterCommandRun>[...state, run];
    return (preflight: const FlutterPreflight.clear(), run: run);
  }

  FlutterProjectScanner _scannerFor(ExecutionEnvironment environment) =>
      FlutterProjectScanner(
        runner: ref
            .read(commandRunnerFactoryProvider)
            .forEnvironment(environment),
        kind: environment.kind,
      );

  /// Two spellings of the same directory, compared the way the filesystem
  /// would. Windows is case-insensitive and both ends may carry a separator.
  static bool _sameDirectory(String a, String b) {
    final left = p.normalize(a.replaceAll('\\', '/'));
    final right = p.normalize(b.replaceAll('\\', '/'));
    return left.toLowerCase() == right.toLowerCase();
  }
}

final flutterLoopProvider =
    NotifierProvider<FlutterLoopController, List<FlutterCommandRun>>(
      FlutterLoopController.new,
    );
