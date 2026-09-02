import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_hook_endpoint.dart';

/// Whether the callback door answers **from inside** an execution environment.
///
/// [AgentHookEndpoint.reaches] answers a different question: it says this app
/// bound *an address* for that kind of environment. That is a fact about the
/// host, and on the owner's machine it stopped being the same fact as "an agent
/// in a distribution can dial it". Measured from inside the distro against the
/// running app, one address at a time:
///
/// ```
/// 172.18.240.1:47821  connect 0.5ms → RST on the first data segment
/// 172.18.240.1:8787   connect 0.6ms → RST     (and 135, and 445: every port)
/// 192.168.68.59:8787  connect 0.8ms → HTTP/1.1 404   (the same app, answering)
/// ```
///
/// So the `vEthernet (WSL (Hyper-V firewall))` address completed its TCP
/// handshake and reset every byte after it, while the very same process served
/// the very same distribution on the host's other addresses. Nothing here can
/// fix that — it is the machine's firewall, not ours — but the app installed
/// four hooks into it anyway and reported `4 installed, 0 skipped`, because a
/// successful *bind* on the Windows side was taken as proof of a reachable
/// *door*. `notifications.status` then read `0 by hook` for the rest of the run
/// with nothing saying why.
///
/// One `curl` per WSL environment per launch, dialling the exact `host:port`
/// the installer is about to write into somebody's config. It sends **no
/// token**: any HTTP status line coming back proves the door, and a `401`
/// proves it as well as a `200` does, so the probe carries no credential.
class AgentHookReachability {
  const AgentHookReachability({
    required this.runners,
    this.dialTimeout = const Duration(seconds: 2),
    this.probeTimeout = const Duration(seconds: 15),
  });

  final CommandRunnerFactory runners;

  /// `curl -m`, matching the bound in the installed hook command itself: a door
  /// too slow for the probe is too slow for the hook.
  final Duration dialTimeout;

  /// The whole probe, `wsl.exe` cold-start included. Generous because install
  /// runs off the startup path, and bounded because a wedged distribution must
  /// not hold the walk open for ever.
  final Duration probeTimeout;

  Future<bool> answersFrom(
    ExecutionEnvironment environment,
    AgentHookEndpoint endpoint,
  ) async {
    final host = endpoint.hostFor(environment.kind);
    if (host == null) return false;
    // Only WSL's address is a guess. Both local kinds dial this very process's
    // loopback, which it is listening on by construction, and an SSH host has
    // no address at all and is refused before it reaches here — so probing
    // them would spend a process per launch to re-learn something already
    // known.
    if (environment.kind != EnvironmentKind.wsl) return true;
    try {
      final result = await runners
          .forEnvironment(environment)
          .run(
            CommandRequest(
              executable: 'curl',
              arguments: [
                '-s',
                '-o',
                '/dev/null',
                '-m',
                '${dialTimeout.inSeconds}',
                '-w',
                '%{http_code}',
                'http://$host/agent-hook',
              ],
            ),
          )
          .timeout(probeTimeout);
      return answered(result.stdout);
    } on Object {
      // A distribution without `curl`, a `wsl.exe` that will not start one, a
      // probe that never came back: each of them also means the hook command
      // this app was about to install could not have run. Reporting a skip is
      // the honest answer, and it is the one that gets investigated.
      return false;
    }
  }

  /// Whether `curl -w %{http_code}` saw a status line at all.
  ///
  /// It prints `000` for every failure that never got one — refused, reset,
  /// timed out — and the three digits of the real status otherwise. The status
  /// itself does not matter: `401` means the door answered.
  static bool answered(String stdout) {
    final code = stdout.trim();
    return code.length == 3 && code != '000' && int.tryParse(code) != null;
  }
}

final agentHookReachabilityProvider = Provider<AgentHookReachability>(
  (ref) =>
      AgentHookReachability(runners: ref.read(commandRunnerFactoryProvider)),
);
