import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'attached_apps.dart';
import 'flutter_app_providers.dart';
import 'flutter_sdk_readings.dart';

/// How many of the pane's bottom rows the announcement is looked for in — sixty
/// covers the gap to the interactive key list at any pane height.
const int kFlutterRunRowsRead = 60;

/// Everything a preflight established, so the caller that acts on it does not
/// ask the same three questions again.
typedef FlutterReadiness = ({
  FlutterPreflight preflight,
  ExecutionEnvironment? environment,
  FlutterSdkReading? sdk,
  FlutterProject? project,
});

/// What a start attempt did: the run it opened, or the line saying why not.
typedef FlutterLoopOutcome = ({
  FlutterPreflight preflight,
  FlutterCommandRun? run,
});

/// One owned lifecycle for a Flutter project: every `flutter` line goes through
/// the resolver and a visible pane (§17), and nothing polls.
class FlutterLoopController extends Notifier<List<FlutterCommandRun>> {
  /// Pane listeners this controller owns, so they come off with the container.
  final Map<String, void Function()> _watchers = <String, void Function()>{};

  @override
  List<FlutterCommandRun> build() {
    ref.onDispose(() {
      for (final stop in _watchers.values.toList(growable: false)) {
        stop();
      }
      _watchers.clear();
    });
    return const <FlutterCommandRun>[];
  }

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

  /// The live run of [kind] for [directory]. "Live" is the pane's own answer,
  /// taken now, so a run whose pane exited does not block the next one.
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
    final resolution = ref
        .read(environmentResolverProvider)
        .resolveFor(project);
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
      // A `null` is "could not be established", deliberately not a block: our
      // own blind spot must not stop a working checkout (§19).
    }

    return (
      preflight: const FlutterPreflight.clear(),
      environment: environment,
      sdk: sdk,
      project: found,
    );
  }

  /// Resolves this project's dependencies in a visible pane: started, not
  /// awaited, because `pub get` on a cold cache has no bound.
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

  /// Launches [project] on [deviceId], arming the auto-attach from the
  /// `--vmservice-out-file`; one run per device, refused by pane, not by claim.
  Future<FlutterLoopOutcome> run({
    required EnvironmentPath project,
    required String deviceId,
    String? sessionId,
    List<String> extraArguments = const <String>[],
  }) async {
    final ready = await readiness(project, kind: FlutterCommandKind.run);
    if (!ready.preflight.isClear) {
      return (preflight: ready.preflight, run: null);
    }

    final existing = liveRunOnDevice(deviceId);
    if (existing != null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.alreadyRunning,
          'A flutter run for ${existing.projectDirectory} is already on '
          '$deviceId, in pane ${existing.paneId}. Stop that one first — a '
          'device runs one app at a time, and a second launch would '
          'replace it without saying so.',
        ),
        run: null,
      );
    }
    try {
      ref
          .read(deviceClaimsProvider)
          .claim(deviceId: deviceId, sessionId: sessionId, verb: 'flutter run');
    } on DeviceBusy catch (busy) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.deviceBusy,
          busy.message,
        ),
        run: null,
      );
    }

    final outFile = await _outFileFor(ready.environment!, ready.project!.name);
    final outcome = await _start(
      kind: FlutterCommandKind.run,
      project: project,
      environment: ready.environment!,
      sdk: ready.sdk!,
      title: 'run · ${ready.project!.name}',
      deviceId: deviceId,
      vmServiceOutFile: outFile,
      extraArguments: <String>[
        '-d',
        deviceId,
        if (outFile != null) '--vmservice-out-file=$outFile',
        ...extraArguments,
      ],
    );
    final started = outcome.run;
    if (started == null) return outcome;

    // Arms the directory subscription `AttachedApps` discovers through, so an
    // app that writes its file attaches with nothing here parsing anything.
    unawaited(ref.read(attachedAppsProvider.notifier).look());
    _watchPaneForAnnouncement(started);
    return outcome;
  }

  /// Runs `flutter analyze` or `flutter test` in a visible pane — a gate has no
  /// natural length — and its exit code becomes a recorded verdict.
  Future<FlutterLoopOutcome> gate(
    EnvironmentPath project,
    FlutterCommandKind kind, {
    List<String> extraArguments = const <String>[],
  }) async {
    assert(kind.isGate, 'gate() is for analyze and test');
    final ready = await readiness(project, kind: kind);
    if (!ready.preflight.isClear) {
      return (preflight: ready.preflight, run: null);
    }
    final live = liveRunFor(project.path, kind);
    if (live != null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.alreadyRunning,
          'flutter ${kind.label} for ${project.path} is already running in '
          'pane ${live.paneId}. Its verdict is recorded when it stops.',
        ),
        run: null,
      );
    }
    return _start(
      kind: kind,
      project: project,
      environment: ready.environment!,
      sdk: ready.sdk!,
      title: '${kind.label} · ${ready.project!.name}',
      extraArguments: extraArguments,
    );
  }

  /// The run in [paneId] with its exit code, or null when that pane was not
  /// ours — nearly every pane exit, so this stays cheap and silent.
  FlutterCommandRun? noteExit(String paneId, int? exitCode) {
    final run = byPane(paneId);
    if (run == null) return null;
    _detachWatcher(paneId);
    final ended = run.copyWith(endedAt: _now, exitCode: exitCode);
    _replace(ended);
    return ended;
  }

  /// Files the `verification_runs` row a finished gate was recorded as.
  void noteRecorded(String paneId, String verificationRunId) {
    final run = byPane(paneId);
    if (run == null) return;
    _replace(run.copyWith(verificationRunId: verificationRunId));
  }

  /// The bottom rows of [paneId]'s buffer, or an empty list when the pane is
  /// gone.
  List<String> tailOf(String paneId, {int lines = kFlutterRunRowsRead}) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) return const <String>[];
    return terminalTailLines(instance.terminal, lines: lines);
  }

  /// The live `flutter run` on [deviceId], whichever project it belongs to.
  FlutterCommandRun? liveRunOnDevice(String deviceId) {
    for (final run in state.reversed) {
      if (run.kind != FlutterCommandKind.run || run.deviceId != deviceId) {
        continue;
      }
      if (livenessOf(run.paneId) == FlutterRunLiveness.running) return run;
    }
    return null;
  }

  /// Ends the process in [paneId] with `endSession`, not `closePane`, which
  /// detaches; the claim is left to lapse, as releasing drops every device.
  Future<FlutterCommandRun?> stop(String paneId) async {
    final run = byPane(paneId);
    if (run == null) return null;
    _watchers.remove(paneId)?.call();
    ref.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
    final stopped = run.copyWith(endedAt: _now);
    _replace(stopped);
    return stopped;
  }

  /// Re-reads what can be re-read about [paneId] and attaches if it now can.
  /// The only place a `--vmservice-out-file` is read, and only on request.
  Future<FlutterCommandRun?> refresh(String paneId) async {
    var run = byPane(paneId);
    if (run == null) return null;
    if (run.vmServiceUri == null) {
      final uri = _addressFromOutFile(run) ?? _addressFromPane(run);
      if (uri != null) run = await _attachTo(run, uri);
    }
    return byPane(paneId) ?? run;
  }

  /// Where `--vmservice-out-file` should point, or null when nothing can be
  /// spelled that this run can write and this app can read.
  Future<String?> _outFileFor(
    ExecutionEnvironment environment,
    String projectName,
  ) async {
    final String directory;
    try {
      final found = await ref.read(flutterAppDiscoveryDirectoryProvider.future);
      directory = found.path;
    } on Object {
      return null;
    }
    return vmServiceOutFileFor(
      kind: environment.kind,
      directory: directory,
      name: vmServiceOutFileName(
        projectName,
        ref.read(idGeneratorProvider).newId(),
      ),
    );
  }

  /// Reads the address `flutter run` wrote, if it has written one.
  Uri? _addressFromOutFile(FlutterCommandRun run) {
    final path = run.vmServiceOutFile;
    if (path == null) return null;
    final local = hostSpellingOfOutFile(path);
    if (local == null) return null;
    final file = File(local);
    if (!file.existsSync()) return null;
    try {
      return normaliseVmServiceUri(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  Uri? _addressFromPane(FlutterCommandRun run) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(run.paneId);
    if (instance == null) return null;
    return vmServiceUriInPaneRows(
      terminalTailLines(instance.terminal, lines: kFlutterRunRowsRead),
    );
  }

  /// Hands [uri] to the registry the five `flutter_*` tools already read, and
  /// records what came back on the run.
  Future<FlutterCommandRun> _attachTo(FlutterCommandRun run, Uri uri) async {
    final AttachedApps apps = ref.read(attachedAppsProvider.notifier);
    var updated = run.copyWith(vmServiceUri: uri.toString());
    try {
      final app = await apps.attach(uri.toString());
      updated = updated.copyWith(appId: app.id);
    } on Object {
      // The address is still the address: losing it would kill the retry, and
      // `flutter_apps` carries the reachability.
      updated = updated.copyWith(appId: AttachedApp.idFor(uri));
    }
    _replace(updated);
    return updated;
  }

  /// Watches the pane's rows for the announcement and stops at the first hit —
  /// a terminal listener, not a timer, so it costs nothing once attached.
  void _watchPaneForAnnouncement(FlutterCommandRun run) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(run.paneId);
    if (instance == null) return;
    void onPainted() {
      final current = byPane(run.paneId);
      if (current == null || current.vmServiceUri != null) {
        _detachWatcher(run.paneId);
        return;
      }
      final uri = vmServiceUriInPaneRows(
        terminalTailLines(instance.terminal, lines: kFlutterRunRowsRead),
      );
      if (uri == null) return;
      _detachWatcher(run.paneId);
      unawaited(_attachTo(current, uri));
    }

    instance.terminal.addListener(onPainted);
    _watchers[run.paneId] = () => instance.terminal.removeListener(onPainted);
  }

  void _detachWatcher(String paneId) => _watchers.remove(paneId)?.call();

  /// Replaces the recorded run for a pane, when there still is one.
  void _replace(FlutterCommandRun updated) {
    state = <FlutterCommandRun>[
      for (final run in state)
        if (run.paneId == updated.paneId) updated else run,
    ];
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
