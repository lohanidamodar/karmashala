import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// **Where `sessions.setMode` and `sessions.setConfigOption` land** (ACP
/// design, C5): the runtime that holds the session's agent puts it into the
/// mode, or sets the option. Set on `DataService.sessionModes` by the ACP
/// runtime; until then every request is refused by [NoSessionModes].
abstract class SessionModeChanger {
  /// Puts [sessionId]'s agent into [modeId]; throws [DataRefused] `invalid`
  /// for a session with no modes or a mode it does not offer, `notFound` for
  /// a session not running here.
  Future<void> setMode(String sessionId, String modeId);

  /// Sets config option [configId] of [sessionId]'s agent to [value] — a
  /// choice's value or a bool; throws [DataRefused] `invalid` for an option
  /// or value the agent does not offer, `notFound` for a session not running
  /// here.
  Future<void> setConfigOption(String sessionId, String configId, Object value);
}

/// **Where `sessions.setModel` lands**: the row is written and, where this
/// server runs the session in a terminal, its agent is moved too. Null on
/// `DataService.sessionModels` refuses the request `unavailable`.
abstract interface class SessionModelChanger {
  /// Records [modelId] for [sessionId] (null: back to the default) and says
  /// what became of the running session. Throws [DataRefused] `notFound` for
  /// a session that is gone.
  Future<SessionModelSet> setModel(String sessionId, String? modelId);
}

/// The default: no session served here has modes or config options.
class NoSessionModes implements SessionModeChanger {
  const NoSessionModes();

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    throw const DataRefused.invalid('This session has no modes to set.');
  }

  @override
  Future<void> setConfigOption(
    String sessionId,
    String configId,
    Object value,
  ) async {
    throw const DataRefused.invalid(
      'This session has no config options to set.',
    );
  }
}
