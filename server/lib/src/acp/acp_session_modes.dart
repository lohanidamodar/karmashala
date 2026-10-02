import 'package:karmashala_acp/karmashala_acp.dart' show AcpRpcError;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../sessions/session_modes.dart';
import 'acp_session_runtime.dart';

/// `sessions.setMode` for the sessions whose agent this server runs over ACP:
/// `session/set_mode` on the runtime, refused in words for everything else.
class AcpSessionModes implements SessionModeChanger {
  AcpSessionModes({required this.runtimeOf});

  /// The running runtime for a session **row** id, or null.
  final AcpSessionRuntime? Function(String sessionId) runtimeOf;

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    final runtime = runtimeOf(sessionId);
    if (runtime == null) {
      throw const DataRefused.notFound(
        'This session is not running here as an ACP agent, so its mode '
        'cannot be set.',
      );
    }
    try {
      await runtime.setMode(modeId);
    } on StateError catch (error) {
      throw DataRefused.invalid(error.message);
    } on AcpRpcError catch (error) {
      throw DataRefused.invalid('The agent refused the mode: ${error.message}');
    }
  }
}
