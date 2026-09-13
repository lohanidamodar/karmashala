import 'package:agent_cli/process.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
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
      found[toolchain] = await _probe(runner, toolchain, now);
    }
    state = {...state, environment.id: found};
    return found;
  }

  /// Drops what is known about [environmentId], so the next ask measures.
  void forget(String environmentId) {
    if (!state.containsKey(environmentId)) return;
    state = {...state}..remove(environmentId);
  }

  Future<ToolchainReading> _probe(
    CommandRunner runner,
    Toolchain toolchain,
    DateTime now,
  ) async {
    try {
      final result = await runner.run(
        CommandRequest(
          executable: toolchain.executable,
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
