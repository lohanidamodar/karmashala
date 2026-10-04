import 'package:karmashala_acp/karmashala_acp.dart' show AcpRpcError;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../sessions/session_modes.dart';
import 'acp_session_runtime.dart';

/// `sessions.setMode` and `sessions.setConfigOption` for the sessions whose
/// agent this server runs over ACP: `session/set_mode` and
/// `session/set_config_option` on the runtime, refused in words for
/// everything else. Its [greeting] tells a client arriving now what every
/// running agent offers, which the runtimes announced before it subscribed.
class AcpSessionModes implements SessionModeChanger {
  AcpSessionModes({required this.runtimeOf, this.running});

  /// The running runtime for a session **row** id, or null.
  final AcpSessionRuntime? Function(String sessionId) runtimeOf;

  /// Every runtime this server holds, for the greeting; null greets nothing.
  final Iterable<AcpSessionRuntime> Function()? running;

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    final runtime = _running(sessionId, 'mode');
    try {
      await runtime.setMode(modeId);
    } on StateError catch (error) {
      throw DataRefused.invalid(error.message);
    } on AcpRpcError catch (error) {
      throw DataRefused.invalid('The agent refused the mode: ${error.message}');
    }
  }

  @override
  Future<void> setConfigOption(
    String sessionId,
    String configId,
    Object value,
  ) async {
    final runtime = _running(sessionId, 'config option');
    try {
      await runtime.setConfigOption(configId, value);
    } on StateError catch (error) {
      throw DataRefused.invalid(error.message);
    } on AcpRpcError catch (error) {
      throw DataRefused.invalid(
        'The agent refused the option: ${error.message}',
      );
    }
  }

  /// The modes, config options, usage and slash commands of every ACP agent
  /// running here, as the runtimes last announced them.
  List<DataChange> greeting() => [
    for (final runtime in running?.call() ?? const <AcpSessionRuntime>[])
      if (!runtime.lifecycle.hasEnded) ...[
        ?runtime.modes,
        ?runtime.configOptions,
        ?runtime.reportedUsage,
        ?runtime.commands,
      ],
  ];

  AcpSessionRuntime _running(String sessionId, String what) =>
      runtimeOf(sessionId) ??
      (throw DataRefused.notFound(
        'This session is not running here as an ACP agent, so its $what '
        'cannot be set.',
      ));
}
