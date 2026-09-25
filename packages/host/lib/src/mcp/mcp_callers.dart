import 'package:karmashala_mcp/protocol.dart';

/// Which session a caller token names: one the daemon's key issued, for a
/// session that is not over. A token for an ended session is refused, as the
/// app refused one it had forgotten; resuming the session makes it good again.
class DaemonMcpCallers implements McpCallerLookup {
  DaemonMcpCallers(this.key, {this.sessionIsOver});

  final McpCallerKey key;

  /// Whether the store says [sessionId] is over or gone. Null without a store:
  /// then every token the key issued is honoured.
  final bool Function(String sessionId)? sessionIsOver;

  @override
  String? sessionFor(String token) {
    final sessionId = key.sessionFor(token);
    if (sessionId == null) return null;
    if (sessionIsOver?.call(sessionId) ?? false) return null;
    return sessionId;
  }
}
