import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../devices/application/device_claims.dart';
import '../../devices/domain/device_claim.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/application/visible_command_pane.dart';
import '../../terminal/data/terminal_grid_text.dart';
import '../../terminal/domain/pane_liveness.dart';
import '../data/flutter_project_scanner.dart';
import '../domain/attached_app.dart';
import '../domain/flutter_command_run.dart';
import '../domain/flutter_preflight.dart';
import '../domain/flutter_project.dart';
import '../domain/flutter_sdk.dart';
import '../domain/vm_service_announcement.dart';
import '../domain/vm_service_out_file.dart';
import '../domain/vm_service_uri.dart';
import 'attached_apps.dart';
import 'flutter_app_providers.dart';
import 'flutter_sdk_readings.dart';

/// How many of the pane's bottom rows the announcement is looked for in.
///
/// A `flutter run` prints its address a few lines before it hands over to the
/// interactive key list, and a Gradle build paints a lot after it. Sixty rows
/// covers the gap at any pane height without reading a whole scrollback on
/// every painted frame.
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
  /// The listeners this controller put on panes it opened, so they come off
  /// when the container does.
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

  /// Launches [project] on [deviceId] and arms the auto-attach.
  ///
  /// **Two routes to the address, and the file is the one that matters.**
  /// `--vmservice-out-file` makes `flutter run` write the `ws://…/ws` address
  /// into the directory this app already watches, which is the mechanism
  /// `AttachedApps` was built on: no parsing, no ambiguity, and several apps at
  /// once reconcile on their own. `look()` is called here so that watch is
  /// armed even when no panel is open.
  ///
  /// The pane's rows are read as a **backstop**, for the run whose file never
  /// arrives — an SSH checkout, a distribution whose translation we could not
  /// spell, a `flutter` old enough to ignore the flag. See
  /// `vmServiceUriInPaneRows` for why that is second choice and not first.
  ///
  /// One run per device, checked twice, and the two answer different
  /// questions. This app's own live runs are the durable half: a pane is
  /// running or it is not, and that never lapses. `DeviceClaims` is the half
  /// that speaks to the *other* tools — it names the session holding the phone
  /// so a `device_tap` is refused by name — and it lapses after a couple of
  /// minutes of silence by design, which a long `flutter run` will reach.
  /// That is the right way round: a lapsed claim frees the phone for the
  /// `device_*` tools while the pane check still refuses a second launch.
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
      ref.read(deviceClaimsProvider).claim(
        deviceId: deviceId,
        sessionId: sessionId,
        verb: 'flutter run',
      );
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

  /// Runs one of the project's own gates — `flutter analyze` or `flutter
  /// test` — in a visible pane, in the repository's environment.
  ///
  /// **The pane, and not an awaited `CommandRunner.run`.** A gate is the one
  /// thing here with a natural end, so awaiting it would be defensible; what
  /// it does not have is a natural *length*, and this repository's own test
  /// suite takes minutes. Holding a tool call open for that is the hang
  /// `SETTLED.md` refused leases over, and it would put the output somewhere
  /// nobody can watch it. So it runs where it can be seen, and its exit code
  /// becomes a recorded verdict through `FlutterGateObserver`.
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

  /// The process in [paneId] has stopped. Returns the run it belonged to with
  /// its exit code on it, or **null when that pane was not one of ours** —
  /// which is nearly every pane exit in the app, so this has to be cheap and
  /// silent.
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

  /// Ends the process in [paneId].
  ///
  /// `endSession` rather than `closePane`: the default there is to *detach* a
  /// live process and keep it alive, which for a `flutter run` would leave an
  /// app on the device that nothing in this app is holding the handle to.
  ///
  /// It does **not** release the device claim, and that is deliberate:
  /// `DeviceClaims.release` drops everything a session holds, so releasing one
  /// device here would take away the others that session is driving. The claim
  /// lapses on its own, which is the mechanism it was built with.
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
  ///
  /// **This is where a `--vmservice-out-file` is read**, and it is read only
  /// because somebody asked: the file is written once by a process we do not
  /// own, so a watch of our own would be a second subscription to the thing
  /// `AttachedApps` already watches, and a poll would be worse.
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
      // The address is still the address: a connection that failed now is
      // worth reporting and worth retrying, and losing the URI would make the
      // retry impossible. `flutter_apps` carries the reachability.
      updated = updated.copyWith(appId: AttachedApp.idFor(uri));
    }
    _replace(updated);
    return updated;
  }

  /// Watches the pane's own rows for the announcement, and stops watching the
  /// moment it has one.
  ///
  /// A listener on the terminal, not a timer: xterm notifies when the process
  /// has written something, so this costs a parse per painted frame of a
  /// starting app and nothing at all once it is attached.
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
    _watchers[run.paneId] = () =>
        instance.terminal.removeListener(onPainted);
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
