import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// **Where `sessions.setMode` lands** (ACP design, C5): the runtime that holds
/// the session's agent puts it into the mode. Set on `DataService.sessionModes`
/// by the ACP runtime; until then every request is refused by [NoSessionModes].
abstract class SessionModeChanger {
  /// Puts [sessionId]'s agent into [modeId]; throws [DataRefused] `invalid`
  /// for a session with no modes or a mode it does not offer, `notFound` for
  /// a session not running here.
  Future<void> setMode(String sessionId, String modeId);
}

/// The default: no session served here has modes.
class NoSessionModes implements SessionModeChanger {
  const NoSessionModes();

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    throw const DataRefused.invalid('This session has no modes to set.');
  }
}
