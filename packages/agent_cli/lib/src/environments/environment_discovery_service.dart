import 'dart:io';

import 'package:logging/logging.dart';
import '../process/command_runner.dart';
import '../process/wsl_distributions.dart';
import '../util/clock.dart';
import './environment_kind.dart';
import './execution_environment.dart';
import './local_environment.dart';

/// Discovers the available execution environments: the always-present local
/// host plus, on Windows, every installed WSL distribution.
///
/// WSL distributions are enumerated by running `wsl.exe --list --quiet` through
/// the **host** [CommandRunner]; this never touches `Process` directly
/// (constraint 6). If WSL is unavailable, only the local host environment is
/// returned (discovery degrades gracefully rather than failing).
class EnvironmentDiscoveryService {
  EnvironmentDiscoveryService({
    required this.host,
    required this.clock,
    bool? hostIsWindows,
    Logger? logger,
  }) : hostIsWindows = hostIsWindows ?? Platform.isWindows,
       _logger = logger ?? Logger('environments');

  final CommandRunner host;
  final Clock clock;
  final Logger _logger;

  /// Whether this machine can have WSL at all. Injected rather than read from
  /// `Platform` so the WSL path stays testable off Windows.
  final bool hostIsWindows;

  Future<List<ExecutionEnvironment>> discover() async {
    final now = clock.nowUtc();
    final environments = <ExecutionEnvironment>[localHostEnvironment(now)];

    // WSL is a Windows feature. Asking a Mac or a Linux box for it spawns a
    // process that cannot exist, and then reports its absence as news — which
    // is how a macOS launch came to log "WSL not available" as though something
    // had gone wrong.
    if (!hostIsWindows) return environments;

    try {
      final result = await host.run(
        const CommandRequest(
          executable: 'wsl.exe',
          arguments: ['--list', '--quiet'],
          timeout: kProbeTimeout,
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
