import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';

import '../domain/flutter_sdk.dart';

/// Where `flutter` is inside one execution environment, measured. What it adds
/// over `AgentDiscoveryService` is a refusal *before* anything is spawned: a
/// WSL PATH finds the Windows Flutter through `/mnt/c`, and running it is the
/// damage (§17).
class FlutterSdkService {
  FlutterSdkService({
    required this.runner,
    required this.environment,
    this.handSetExecutable,
  });

  final CommandRunner runner;
  final ExecutionEnvironment environment;

  /// The `flutter` a person named for this environment, or null. Handed in
  /// rather than read, so this stays a pure measurer.
  final String? handSetExecutable;

  EnvironmentKind get _kind => environment.kind;

  /// Locates `flutter` and reads its version, or refuses in words.
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

    // §20's third rule: a hand-set path is never overruled by discovery, and
    // never fallen back from — a silent fallback is how a user comes to
    // believe their row is in use when it is not.
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
    // A version we could not read is recorded as unknown, not refused (§19).
    return FlutterSdkReading(
      environmentId: environment.id,
      readAt: now,
      executable: path,
      version: versioned.ok ? parseAgentVersion(versioned.stdout) : null,
    );
  }

  /// The reading for a path a person named. The §17 refusal applies before
  /// anything is spawned: a typed `/mnt/c/…/flutter` is the same disaster as a
  /// resolved one.
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
    // As on the PATH branch: unreadable version, not a refused path (§19).
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
