import '../../../core/process/command_runner.dart';
import '../../agents/data/agent_discovery_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/flutter_sdk.dart';

/// Where `flutter` is inside one execution environment, measured.
///
/// **Modelled on `AgentDiscoveryService` on purpose**, and it reuses that
/// file's `locateRequest` and `parseAgentVersion` rather than re-deriving
/// them: the lookup is the same question — *where is this CLI in this
/// environment, and what version answers* — and a second spelling of `where` /
/// `command -v` is a second thing to get wrong.
///
/// What it adds, and what nothing about an agent CLI needed, is a refusal
/// **before** anything is spawned. See `windowsInstallRefusal`: a WSL
/// distribution's PATH ordinarily finds the Windows Flutter through `/mnt/c`,
/// and running it to read its version would already have done the damage.
class FlutterSdkService {
  FlutterSdkService({
    required this.runner,
    required this.environment,
    this.handSetExecutable,
  });

  final CommandRunner runner;
  final ExecutionEnvironment environment;

  /// The `flutter` a person named for this environment, or null.
  ///
  /// Handed in rather than read, so this stays a pure measurer with no opinion
  /// about where a preference is kept — `FlutterSdkReadings` is the one place
  /// that knows, and a test can put a path here without standing up settings.
  final String? handSetExecutable;

  EnvironmentKind get _kind => environment.kind;

  /// Locates `flutter` and reads its version, or refuses in words.
  ///
  /// [now] is passed in rather than read, so the age on the reading is the
  /// clock the rest of the app is using.
  Future<FlutterSdkReading> read(DateTime now) async {
    final reachability = reachabilityRequest(_kind);
    if (reachability != null) {
      final CommandResult alive;
      try {
        alive = await runner.run(reachability);
      } on CommandException catch (error) {
        return _unreachable(now, error.message);
      }
      if (!alive.ok) {
        return _unreachable(now, firstNonEmptyLine(alive.stderr) ?? 'it did not answer');
      }
    }

    // **The person's own answer comes first, and PATH is never asked.**
    // §20's third rule: a hand-set path is never overruled by discovery — so
    // it is not "tried and fallen back from" either, because a fallback that
    // quietly finds something else is how a user comes to believe their row is
    // being used when it is not. A hand-set path that will not run is refused
    // by name, and clearing the row is what restores the PATH probe.
    final handSet = handSetExecutable?.trim();
    if (handSet != null && handSet.isNotEmpty) {
      return _readHandSet(now, handSet);
    }

    final name = flutterExecutableFor(_kind);
    final CommandResult located;
    try {
      located = await runner.run(locateRequest(_kind, name));
    } on CommandException catch (error) {
      return _unreachable(now, error.message);
    }
    final path = located.ok ? firstNonEmptyLine(located.stdout) : null;
    if (path == null || path.isEmpty) {
      return FlutterSdkReading.refused(
        environmentId: environment.id,
        readAt: now,
        refusal: FlutterSdkRefusal.notFound,
        reason:
            'No Flutter SDK is on PATH in ${environment.name}. Install one '
            'there, or point this checkout at an environment that has one.',
      );
    }

    // Before the version probe, because the version probe is the run.
    final windows = windowsInstallRefusal(_kind, path);
    if (windows != null) {
      return FlutterSdkReading.refused(
        environmentId: environment.id,
        readAt: now,
        refusal: FlutterSdkRefusal.windowsInstallOnPosixPath,
        reason: windows,
      );
    }

    final CommandResult versioned;
    try {
      versioned = await runner.run(
        CommandRequest(executable: path, arguments: const <String>['--version']),
      );
    } on CommandException catch (error) {
      return FlutterSdkReading.refused(
        environmentId: environment.id,
        readAt: now,
        refusal: FlutterSdkRefusal.versionUnreadable,
        reason:
            'Flutter is at $path in ${environment.name} but could not be run: '
            '${error.message}',
      );
    }
    // A version we could not read is not a Flutter we refuse to use — the path
    // is still the path. It is recorded as unknown rather than as a number
    // nobody measured (§19).
    return FlutterSdkReading(
      environmentId: environment.id,
      readAt: now,
      executable: path,
      version: versioned.ok ? parseAgentVersion(versioned.stdout) : null,
    );
  }

  /// The reading for a path a person named for this environment.
  ///
  /// The §17 refusal applies here **exactly as it does to a located path, and
  /// before anything is spawned**: a person can type
  /// `/mnt/c/Users/…/flutter/bin/flutter` into the field as easily as WSL's
  /// PATH can resolve to it, and running it is the same disaster either way.
  /// The harm is in the running, not in the looking. Only the sentence differs
  /// — see `windowsInstallRefusal`'s `handSet`.
  Future<FlutterSdkReading> _readHandSet(DateTime now, String path) async {
    final windows = windowsInstallRefusal(_kind, path, handSet: true);
    if (windows != null) {
      return FlutterSdkReading.refused(
        environmentId: environment.id,
        readAt: now,
        refusal: FlutterSdkRefusal.windowsInstallOnPosixPath,
        reason: windows,
      );
    }
    final CommandResult versioned;
    try {
      versioned = await runner.run(
        CommandRequest(executable: path, arguments: const <String>['--version']),
      );
    } on CommandException catch (error) {
      return FlutterSdkReading.refused(
        environmentId: environment.id,
        readAt: now,
        refusal: FlutterSdkRefusal.handSetUnusable,
        reason:
            'The Flutter SDK path set for ${environment.name} is $path, and it '
            'could not be run: ${error.message}. Correct it in Settings → '
            'Environments, or clear it to look on PATH again.',
      );
    }
    // A version we could not read is not a path we refuse — the same rule the
    // PATH branch follows, and for the same reason (§19).
    return FlutterSdkReading(
      environmentId: environment.id,
      readAt: now,
      executable: path,
      version: versioned.ok ? parseAgentVersion(versioned.stdout) : null,
    );
  }

  FlutterSdkReading _unreachable(DateTime now, String detail) =>
      FlutterSdkReading.refused(
        environmentId: environment.id,
        readAt: now,
        refusal: FlutterSdkRefusal.environmentUnreachable,
        reason:
            '${environment.name} could not be reached, so whether it has a '
            'Flutter SDK is unknown rather than no: $detail. Start it and ask '
            'again.',
      );
}
