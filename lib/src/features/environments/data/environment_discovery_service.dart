import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner.dart';
import '../../../core/util/clock.dart';
import '../domain/environment_kind.dart';
import '../domain/execution_environment.dart';
import '../domain/local_environment.dart';

/// Parses the output of `wsl.exe --list --quiet` into distribution names.
///
/// Pure and testable. `wsl.exe` emits UTF-16, so after decoding the text often
/// contains interleaved NUL (`0x00`) bytes and a leading byte-order mark
/// (`0xFEFF`); both are stripped here. Blank lines are dropped. (Deeper
/// Windows/WSL output hardening is Loop 11.)
List<String> parseWslDistributions(String rawOutput) {
  final cleaned = String.fromCharCodes(
    rawOutput.codeUnits.where((c) => c != 0x00 && c != 0xFEFF),
  );
  return cleaned
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

/// Discovers the available execution environments: the always-present
/// Windows-native host plus every installed WSL distribution.
///
/// WSL distributions are enumerated by running `wsl.exe --list --quiet` through
/// the **host** [CommandRunner]; this never touches `Process` directly
/// (constraint 6). If WSL is unavailable, only the Windows environment is
/// returned (discovery degrades gracefully rather than failing).
class EnvironmentDiscoveryService {
  EnvironmentDiscoveryService({
    required this.host,
    required this.clock,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.named('environments');

  final CommandRunner host;
  final Clock clock;
  final AppLogger _logger;

  Future<List<ExecutionEnvironment>> discover() async {
    final now = clock.nowUtc();
    final environments = <ExecutionEnvironment>[localWindowsEnvironment(now)];

    try {
      final result = await host.run(
        const CommandRequest(
          executable: 'wsl.exe',
          arguments: ['--list', '--quiet'],
        ),
      );
      if (result.ok) {
        for (final distro in parseWslDistributions(result.stdout)) {
          environments.add(
            ExecutionEnvironment(
              id: 'wsl:$distro',
              kind: EnvironmentKind.wsl,
              name: distro,
              wslDistribution: distro,
              createdAt: now,
            ),
          );
        }
      } else {
        _logger.warning(
          'wsl.exe --list exited ${result.exitCode}; no WSL distributions added.',
        );
      }
    } on CommandException catch (e) {
      _logger.info('WSL not available (${e.message}); Windows-only.');
    }

    return environments;
  }
}
