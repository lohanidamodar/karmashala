import 'package:agent_cli/discovery.dart' show locateOnPath;
import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import '../../flutter_apps/application/flutter_sdk_readings.dart';
import '../domain/toolchain.dart';

/// How long a reading is worth reusing before the panel measures again.
/// Toolchains move when somebody installs one, which is rare and deliberate.
const Duration kToolchainReadingFreshFor = Duration(minutes: 10);

/// **What each machine can build with, measured and kept with its age.**
///
/// In memory, like `FlutterSdkReadings` and for the same reason: PATH moves,
/// and a reading persisted across runs would be a claim about a machine nobody
/// has looked at this launch.
///
/// A missing entry is **"we have not looked"**, never "it is not there" (§19).
class ToolchainReadings
    extends Notifier<Map<String, Map<Toolchain, ToolchainReading>>> {
  @override
  Map<String, Map<Toolchain, ToolchainReading>> build() => const {};

  /// What was last read for [environmentId], however old. Empty for a machine
  /// nobody has asked.
  Map<Toolchain, ToolchainReading> cached(String environmentId) =>
      state[environmentId] ?? const {};

  /// Whether anything at all has been read for [environmentId].
  bool hasLooked(String environmentId) => state.containsKey(environmentId);

  /// Measures every toolchain on [environment], reusing readings that are
  /// still fresh unless [force] says to look again.
  ///
  /// **Never throws.** A machine that cannot be reached answers `unknown` for
  /// everything, which is what the panel then says.
  Future<Map<Toolchain, ToolchainReading>> readAll(
    ExecutionEnvironment environment, {
    bool force = false,
  }) async {
    final now = ref.read(clockProvider).nowUtc();
    final held = state[environment.id] ?? const <Toolchain, ToolchainReading>{};
    final runner = ref
        .read(commandRunnerFactoryProvider)
        .forEnvironment(environment);

    final found = <Toolchain, ToolchainReading>{};
    for (final toolchain in Toolchain.values) {
      final previous = held[toolchain];
      if (!force &&
          previous != null &&
          now.difference(previous.readAt) < kToolchainReadingFreshFor) {
        found[toolchain] = previous;
        continue;
      }
      if (toolchain.impossibleOn(environment.kind)) {
        found[toolchain] = ToolchainReading.impossible(toolchain, now);
        continue;
      }
      // Flutter is not probed here. `FlutterSdkService` already locates it —
      // `flutter.bat` on Windows, a hand-set path never overruled, and §17's
      // refusal for a POSIX `flutter` that is really the Windows install
      // through a drive mount. A second lookup got all three wrong.
      found[toolchain] = toolchain == Toolchain.flutterSdk
          ? _fromFlutterReading(
              await ref
                  .read(flutterSdkReadingsProvider.notifier)
                  .readFor(environment, force: force),
              now,
            )
          : await _probe(runner, environment, toolchain, now);
    }
    state = {...state, environment.id: found};
    return found;
  }

  /// Drops what is known about [environmentId], so the next ask measures.
  void forget(String environmentId) {
    if (!state.containsKey(environmentId)) return;
    state = {...state}..remove(environmentId);
  }

  ToolchainReading _fromFlutterReading(FlutterSdkReading reading, DateTime now) {
    if (reading.isUsable) {
      return ToolchainReading(
        toolchain: Toolchain.flutterSdk,
        status: reading.version == null
            ? ToolchainStatus.presentVersionUnknown
            : ToolchainStatus.present,
        readAt: reading.readAt,
        version: reading.version,
      );
    }
    return ToolchainReading(
      toolchain: Toolchain.flutterSdk,
      status: switch (reading.refusal) {
        FlutterSdkRefusal.notFound => ToolchainStatus.missing,
        FlutterSdkRefusal.environmentUnreachable => ToolchainStatus.unknown,
        FlutterSdkRefusal.windowsInstallOnPosixPath => ToolchainStatus.refused,
        // Located and running, and it would not say which version it is.
        FlutterSdkRefusal.versionUnreadable =>
          ToolchainStatus.presentVersionUnknown,
        // A path a *person* named and that will not run. Refused rather than
        // missing: only correcting or clearing that row helps, and saying
        // "not found" would send them looking for an install instead.
        FlutterSdkRefusal.handSetUnusable => ToolchainStatus.refused,
        null => ToolchainStatus.unknown,
      },
      readAt: reading.readAt,
      detail: reading.reason,
    );
  }

  Future<ToolchainReading> _probe(
    CommandRunner runner,
    ExecutionEnvironment environment,
    Toolchain toolchain,
    DateTime now,
  ) async {
    // Located before it is run, the way agent discovery already locates a CLI.
    // Running the bare name would answer "missing" for anything Windows
    // resolves through PATHEXT — `flutter.bat` above all (CLAUDE.md §17).
    //
    // Through [locateOnPath] rather than a bare [locateRequest]: it asks the
    // interactive shell when the login shell comes back empty. Toolchains live
    // on PATH via `~/.zshrc` as often as agent CLIs do, and a login shell never
    // reads it — so from a Finder launch this panel reported every toolchain
    // "missing" on a machine that has them all.
    final name = toolchain.executableFor(environment.kind);
    try {
      final located = await locateOnPath(runner, environment.kind, [name]);
      if ((located ?? '').isEmpty) {
        return ToolchainReading(
          toolchain: toolchain,
          status: ToolchainStatus.missing,
          readAt: now,
          detail: 'no $name on PATH in ${environment.name}',
        );
      }
      final result = await runner.run(
        CommandRequest(
          executable: name,
          arguments: toolchain.arguments,
          timeout: const Duration(seconds: 20),
        ),
      );
      if (!result.ok) {
        return ToolchainReading(
          toolchain: toolchain,
          status: ToolchainStatus.missing,
          readAt: now,
          detail: firstLineOf(result.stderr) ?? firstLineOf(result.stdout),
        );
      }
      // `java -version` writes to stderr, and has since forever.
      final said = firstLineOf(result.stdout) ?? firstLineOf(result.stderr);
      return ToolchainReading(
        toolchain: toolchain,
        status: said == null
            ? ToolchainStatus.presentVersionUnknown
            : ToolchainStatus.present,
        readAt: now,
        version: said,
      );
    } on Object catch (error) {
      // The process could not be started at all — an unreachable machine, a
      // shell that would not open. That is not the same as the tool being
      // absent, and saying "missing" here would be a claim nobody measured.
      return ToolchainReading(
        toolchain: toolchain,
        status: ToolchainStatus.unknown,
        readAt: now,
        detail: '$error',
      );
    }
  }
}

final toolchainReadingsProvider =
    NotifierProvider<
      ToolchainReadings,
      Map<String, Map<Toolchain, ToolchainReading>>
    >(ToolchainReadings.new);

/// Whether a machine is being measured right now, so its row can say so and
/// refuse a second press.
class ToolchainProbesRunning extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void start(String environmentId) => state = {...state, environmentId};
  void finish(String environmentId) =>
      state = {...state}..remove(environmentId);
}

final toolchainProbesRunningProvider =
    NotifierProvider<ToolchainProbesRunning, Set<String>>(
      ToolchainProbesRunning.new,
    );

/// Measures [environment] and keeps the running set honest whatever happens.
Future<void> measureToolchains(
  ProviderContainer container,
  ExecutionEnvironment environment, {
  bool force = false,
}) async {
  final running = container.read(toolchainProbesRunningProvider.notifier);
  if (container.read(toolchainProbesRunningProvider).contains(environment.id)) {
    return;
  }
  running.start(environment.id);
  try {
    await container
        .read(toolchainReadingsProvider.notifier)
        .readAll(environment, force: force);
  } finally {
    running.finish(environment.id);
  }
}
