import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show HostedRun, HostedRunFamily, hostedRunPaneId;
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:path/path.dart' as p;

import '../domain/uuid.dart';
import '../server/gui_session.dart';
import 'attached_apps.dart';
import '../devices/server_device_claims.dart' show FlutterDeviceClaims;
import 'flutter_sdk_readings.dart';
import 'hosted_runs.dart';

/// How many of a run's bottom rows the announcement is looked for in.
const int kFlutterRunRowsRead = 60;

/// How much of a finished gate's screen is kept as its artifact.
const int kFlutterGateRowsRecorded = 400;

/// The devices that open a window on the server's own desktop.
const Set<String> kDesktopDeviceIds = {'macos', 'windows', 'linux'};

/// Everything a preflight established.
typedef FlutterReadiness = ({
  FlutterPreflight preflight,
  ExecutionEnvironment? environment,
  FlutterSdkReading? sdk,
  FlutterProject? project,
});

/// What a start attempt did: the run it opened, or why not.
typedef FlutterLoopOutcome = ({
  FlutterPreflight preflight,
  FlutterCommandRun? run,
});

/// One lifecycle for a Flutter project, run by the server (slice 3d): every
/// `flutter` line is a hosted run any client can watch, the app it launches
/// is attached here, and a gate's exit becomes a recorded verdict.
class ServerFlutterLoop {
  ServerFlutterLoop({
    required this.hosted,
    required this.sdk,
    required this.apps,
    required this.rows,
    required this.recorder,
    this.runners = const CommandRunnerFactory(),
    this.hostEnvironment = const {},
    required this.claims,
    this.androidSdkRoot,
    String? operatingSystem,
    String Function()? newId,
    DateTime Function()? clock,
  }) : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _newId = newId ?? newUuid,
       _now = clock ?? _utcNow;

  final HostedRuns hosted;
  final ServerFlutterSdk sdk;
  final ServerAttachedApps apps;
  final CheckoutRows rows;
  final CommandCheckRecorder recorder;
  final CommandRunnerFactory runners;
  final Map<String, String> hostEnvironment;
  final FlutterDeviceClaims claims;

  /// The Android SDK the server resolved for this machine, or null: laid
  /// into every Flutter command here as ANDROID_HOME, so flutter run talks to
  /// the same adb (and adb daemon) as the device tools and the pane.
  final Future<String?> Function()? androidSdkRoot;
  final String _operatingSystem;
  final String Function() _newId;
  final DateTime Function() _now;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final _runs = <String, FlutterCommandRun>{};
  final _runIds = <String, String>{};
  final _watchers = <String, StreamSubscription<void>>{};
  Future<void> _queue = Future<void>.value();

  /// Every verdict a gate's exit set off has been written.
  Future<void> drain() => _queue;

  /// The runs started here, oldest first.
  List<FlutterCommandRun> get runs => List.unmodifiable(_runs.values);

  FlutterCommandRun? byPane(String paneId) => _runs[paneId];

  FlutterRunLiveness livenessOf(String paneId) {
    final runId = _runIds[paneId];
    if (runId == null) return FlutterRunLiveness.unknown;
    return switch (hosted.livenessOf(runId)) {
      HostedRunLiveness.running => FlutterRunLiveness.running,
      HostedRunLiveness.finished => FlutterRunLiveness.finished,
      HostedRunLiveness.unknown => FlutterRunLiveness.unknown,
    };
  }

  List<String> tailOf(String paneId, {int lines = kFlutterRunRowsRead}) {
    final runId = _runIds[paneId];
    return runId == null ? const [] : hosted.tailOf(runId, lines: lines);
  }

  FlutterCommandRun? liveRunFor(String directory, FlutterCommandKind kind) {
    for (final run in _runs.values.toList().reversed) {
      if (run.kind != kind) continue;
      if (!_sameDirectory(run.projectDirectory, directory)) continue;
      if (livenessOf(run.paneId) == FlutterRunLiveness.running) return run;
    }
    return null;
  }

  FlutterCommandRun? liveRunOnDevice(String deviceId) {
    for (final run in _runs.values.toList().reversed) {
      if (run.kind != FlutterCommandKind.run || run.deviceId != deviceId) {
        continue;
      }
      if (livenessOf(run.paneId) == FlutterRunLiveness.running) return run;
    }
    return null;
  }

  /// Everything that must be true before [kind] can run in [project], in the
  /// order that makes each refusal actionable.
  Future<FlutterReadiness> readiness(
    EnvironmentPath project, {
    required FlutterCommandKind kind,
  }) async {
    FlutterReadiness blocked(
      FlutterPreflightProblem problem,
      String reason, {
      ExecutionEnvironment? environment,
      FlutterSdkReading? sdk,
      FlutterProject? project,
    }) => (
      preflight: FlutterPreflight.blocked(problem, reason),
      environment: environment,
      sdk: sdk,
      project: project,
    );

    final environment = rows.environment(project.environmentId);
    if (environment == null) {
      return blocked(
        FlutterPreflightProblem.environmentUnresolved,
        'The environment ${project.environmentId} is not recorded. Pick the '
        'checkout in Karmashala, or record the environment it belongs to, '
        'before running Flutter in it.',
      );
    }
    final refused = hosted.refusalFor(environment);
    if (refused != null) {
      return blocked(
        FlutterPreflightProblem.environmentUnresolved,
        refused,
        environment: environment,
      );
    }
    final reading = await sdk.readFor(environment);
    if (!reading.isUsable) {
      return blocked(
        FlutterPreflightProblem.noSdk,
        reading.reason,
        environment: environment,
        sdk: reading,
      );
    }
    final scanner = FlutterProjectScanner(
      runner: runners.forEnvironment(environment),
      kind: environment.kind,
    );
    final found = await scanner.projectAt(project);
    if (found == null) {
      return blocked(
        FlutterPreflightProblem.notAFlutterProject,
        '${project.path} has no pubspec.yaml with a flutter: key, so there '
        'is no Flutter project there to ${kind.label}. list_checkouts '
        'names the checkouts this workspace knows.',
        environment: environment,
        sdk: reading,
      );
    }
    if (kind == FlutterCommandKind.run && !found.isRunnable) {
      return blocked(
        FlutterPreflightProblem.notRunnable,
        '${found.name} depends on the Flutter SDK but has no top-level '
        'flutter: section, so it is a package or a plugin rather than an '
        'app: there is no entrypoint for flutter run. Run its example, '
        'or the app that depends on it.',
        environment: environment,
        sdk: reading,
        project: found,
      );
    }
    // `pub get` is what produces the packages; a null is our blind spot and
    // never a block.
    if (kind != FlutterCommandKind.pubGet &&
        await scanner.hasPackageConfig(project) == false) {
      return blocked(
        FlutterPreflightProblem.noPackages,
        '${found.name} has no .dart_tool/package_config.json, so nothing '
        'has resolved its dependencies yet. Run flutter_run with '
        'action "pubGet" first; a fresh worktree always needs it.',
        environment: environment,
        sdk: reading,
        project: found,
      );
    }
    return (
      preflight: const FlutterPreflight.clear(),
      environment: environment,
      sdk: reading,
      project: found,
    );
  }

  /// Resolves [project]'s dependencies: started, not awaited.
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
          'A pub get for ${project.path} is already running in session '
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
      ready: ready,
      title: 'pub get · ${ready.project!.name}',
    );
  }

  /// Launches [project] on [deviceId] and attaches to it once it announces
  /// itself; one run per device.
  Future<FlutterLoopOutcome> run({
    required EnvironmentPath project,
    required String deviceId,
    String? sessionId,
    List<String> extraArguments = const [],
  }) async {
    if (kDesktopDeviceIds.contains(deviceId) &&
        !hasGuiSession(hostEnvironment, operatingSystem: _operatingSystem)) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.noDevice,
          '"$deviceId" opens a window on the Karmashala server\'s own desktop, '
          'and this server has none (no display). Run on a phone, an '
          'emulator or "chrome" instead, or on a server with a desktop.',
        ),
        run: null,
      );
    }
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
          '$deviceId, in session ${existing.paneId}. Stop that one first — a '
          'device runs one app at a time, and a second launch would '
          'replace it without saying so.',
        ),
        run: null,
      );
    }
    final busy = claims.claim(
      deviceId: deviceId,
      sessionId: sessionId,
      verb: 'flutter run',
    );
    if (busy != null) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.deviceBusy,
          busy,
        ),
        run: null,
      );
    }
    final outFile = vmServiceOutFileFor(
      kind: ready.environment!.kind,
      directory: apps.directory.path,
      name: vmServiceOutFileName(ready.project!.name, _newId()),
    );
    final outcome = await _start(
      kind: FlutterCommandKind.run,
      project: project,
      ready: ready,
      title: 'run · ${ready.project!.name}',
      deviceId: deviceId,
      vmServiceOutFile: outFile,
      extraArguments: [
        '-d',
        deviceId,
        if (outFile != null) '--vmservice-out-file=$outFile',
        ...extraArguments,
      ],
    );
    final started = outcome.run;
    if (started == null) return outcome;
    // Arms the directory watch the out-file is found through.
    unawaited(apps.look());
    _watchForAnnouncement(started);
    return outcome;
  }

  /// `flutter analyze` or `flutter test`; its exit becomes a verdict.
  Future<FlutterLoopOutcome> gate(
    EnvironmentPath project,
    FlutterCommandKind kind, {
    List<String> extraArguments = const [],
    String? sessionId,
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
          'session ${live.paneId}. Its verdict is recorded when it stops.',
        ),
        run: null,
      );
    }
    return _start(
      kind: kind,
      project: project,
      ready: ready,
      title: '${kind.label} · ${ready.project!.name}',
      extraArguments: extraArguments,
      sessionId: sessionId,
    );
  }

  /// Ends the process — stopped, not detached.
  Future<FlutterCommandRun?> stop(String paneId) async {
    final run = _runs[paneId];
    final runId = _runIds[paneId];
    if (run == null || runId == null) return null;
    unawaited(_watchers.remove(paneId)?.cancel());
    await hosted.stop(runId);
    final stopped = _runs[paneId];
    if (stopped != null && stopped.endedAt == null) {
      _runs[paneId] = stopped.copyWith(endedAt: _now());
    }
    return _runs[paneId];
  }

  /// Reads the out-file (or the screen) again and attaches if it now can.
  Future<FlutterCommandRun?> refresh(String paneId) async {
    var run = _runs[paneId];
    if (run == null) return null;
    if (run.vmServiceUri == null) {
      final uri = _addressFromOutFile(run) ?? _addressFromScreen(run);
      if (uri != null) run = await _attachTo(run, uri);
    }
    return _runs[paneId] ?? run;
  }

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

  Uri? _addressFromScreen(FlutterCommandRun run) =>
      vmServiceUriInPaneRows(tailOf(run.paneId));

  Future<FlutterCommandRun> _attachTo(FlutterCommandRun run, Uri uri) async {
    var updated = run.copyWith(vmServiceUri: uri.toString());
    try {
      final app = await apps.attach(uri.toString());
      updated = updated.copyWith(appId: app.id);
    } on Object {
      // The address is still the address; flutter_apps says it is unreachable.
      updated = updated.copyWith(appId: AttachedApp.idFor(uri));
    }
    if (_runs.containsKey(run.paneId)) _runs[run.paneId] = updated;
    return updated;
  }

  /// Watches the run's output for the announcement and stops at the first.
  void _watchForAnnouncement(FlutterCommandRun run) {
    final runId = _runIds[run.paneId];
    if (runId == null) return;
    _watchers[run.paneId] = hosted.outputOf(runId).listen((_) {
      final current = _runs[run.paneId];
      if (current == null || current.vmServiceUri != null) {
        unawaited(_watchers.remove(run.paneId)?.cancel());
        return;
      }
      final uri = _addressFromScreen(current);
      if (uri == null) return;
      unawaited(_watchers.remove(run.paneId)?.cancel());
      unawaited(_attachTo(current, uri));
    });
  }

  /// ANDROID_HOME for a Flutter command on this machine, none for a WSL
  /// distribution (its own SDK, its own adb daemon).
  Future<Map<String, String>> _androidVariables(
    ExecutionEnvironment environment,
  ) async {
    if (environment.kind == EnvironmentKind.wsl) return const {};
    final root = await androidSdkRoot?.call();
    return root == null ? const {} : {'ANDROID_HOME': root};
  }

  Future<FlutterLoopOutcome> _start({
    required FlutterCommandKind kind,
    required EnvironmentPath project,
    required FlutterReadiness ready,
    required String title,
    List<String> extraArguments = const [],
    String? deviceId,
    String? vmServiceOutFile,
    String? sessionId,
  }) async {
    final argv = [ready.sdk!.executable!, ...kind.arguments, ...extraArguments];
    final environment = ready.environment!;
    final HostedRun hostedRun;
    try {
      hostedRun = await hosted.start(
        variables: await _androidVariables(environment),
        argv: argv,
        directory: project,
        environment: environment,
        title: title,
        family: HostedRunFamily.flutter,
        onEnded: (ended) => _noteExit(ended, sessionId),
      );
    } on HostedRunRefused catch (refused) {
      return (
        preflight: FlutterPreflight.blocked(
          FlutterPreflightProblem.noPane,
          refused.message,
        ),
        run: null,
      );
    }
    final paneId = hostedRunPaneId(hostedRun.runId);
    final run = FlutterCommandRun(
      paneId: paneId,
      kind: kind,
      projectDirectory: project.path,
      environmentId: environment.id,
      command: argv,
      startedAt: hostedRun.startedAt,
      deviceId: deviceId,
      vmServiceOutFile: vmServiceOutFile,
    );
    _runs[paneId] = run;
    _runIds[paneId] = hostedRun.runId;
    return (preflight: const FlutterPreflight.clear(), run: run);
  }

  void _noteExit(HostedRun ended, String? sessionId) {
    final paneId = hostedRunPaneId(ended.runId);
    final run = _runs[paneId];
    if (run == null) return;
    unawaited(_watchers.remove(paneId)?.cancel());
    final done = run.copyWith(
      endedAt: ended.endedAt ?? _now(),
      exitCode: ended.exitCode,
    );
    _runs[paneId] = done;
    if (!done.kind.isGate) return;
    final tail = tailOf(paneId, lines: kFlutterGateRowsRecorded);
    _queue = _queue
        .then((_) => _record(done, tail, sessionId))
        // A verdict that could not be written must not stop the next one.
        .catchError((Object _) {});
  }

  Future<void> _record(
    FlutterCommandRun run,
    List<String> tail,
    String? sessionId,
  ) async {
    final recorded = await recorder.recordOne(
      title: 'flutter ${run.kind.label} · ${run.projectDirectory}',
      command: run.command,
      workingDirectory: run.projectDirectory,
      environmentId: run.environmentId,
      startedAt: run.startedAt,
      exitCode: run.exitCode,
      output: tail.join('\n'),
      sessionId: sessionId,
      producedBySessionId: sessionId,
    );
    final current = _runs[run.paneId];
    if (current != null) {
      _runs[run.paneId] = current.copyWith(verificationRunId: recorded.id);
    }
  }

  Future<void> close() async {
    for (final watcher in _watchers.values.toList()) {
      await watcher.cancel();
    }
    _watchers.clear();
  }

  static bool _sameDirectory(String a, String b) =>
      p.normalize(a.replaceAll('\\', '/')).toLowerCase() ==
      p.normalize(b.replaceAll('\\', '/')).toLowerCase();
}
