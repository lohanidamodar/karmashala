import 'package:agent_cli/descriptors.dart' show AgentStatusReport;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionConfigOptionsChanged, SessionModesChanged;

/// What an [AcpSessionRuntime] asks of the server around it: where its
/// status goes, the checkpoint hold before a write, who hears of its modes,
/// its config options and its rows. One interface so a test hands the
/// runtime a recorder.
abstract class AcpRuntimeHost {
  const AcpRuntimeHost();

  /// The default: nobody is told anything.
  static const AcpRuntimeHost none = _NoHost();

  /// The agent's own word about what it is doing, for the row [sessionId].
  void status(String sessionId, AgentStatusReport report);

  /// Completes once the before-turn checkpoint of [sessionId] is taken, so a
  /// write the agent is about to make lands after it. Bounded by the caller.
  Future<void> checkpointSettled(String sessionId);

  /// Paths a tool of [sessionId] is about to touch this turn.
  void checkpointTouched(String sessionId, Iterable<String> paths);

  /// The prompt that starts [sessionId]'s next turn, for its checkpoint label.
  void checkpointPrompt(String sessionId, String prompt);

  /// The agent announced or changed its modes.
  void modesChanged(SessionModesChanged change);

  /// The agent announced or changed its config options (a model, a flag).
  void configOptionsChanged(SessionConfigOptionsChanged change);

  /// `session_messages` rows of [sessionId] were written.
  void messagesChanged(String sessionId);

  void log(String message);
}

final class _NoHost extends AcpRuntimeHost {
  const _NoHost();

  @override
  void status(String sessionId, AgentStatusReport report) {}

  @override
  Future<void> checkpointSettled(String sessionId) async {}

  @override
  void checkpointTouched(String sessionId, Iterable<String> paths) {}

  @override
  void checkpointPrompt(String sessionId, String prompt) {}

  @override
  void modesChanged(SessionModesChanged change) {}

  @override
  void configOptionsChanged(SessionConfigOptionsChanged change) {}

  @override
  void messagesChanged(String sessionId) {}

  @override
  void log(String message) {}
}
