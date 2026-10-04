import '../errors.dart';
import '../types/permission.dart';
import '../types/session_update.dart';

/// What the agent may ask of the client during a session. Throw an
/// [AcpRpcError] to answer with a specific code (for instance
/// `JsonRpcErrorCodes.resourceNotFound`); any other exception becomes -32603.
abstract class AcpClientHandler {
  const AcpClientHandler();

  Future<PermissionOutcome> requestPermission(
    String sessionId,
    ToolCallUpdate toolCall,
    List<PermissionOption> options,
  );

  /// [line] is 1-based; [limit] a count of lines from it.
  Future<String> readTextFile(
    String sessionId,
    String path, {
    int? line,
    int? limit,
  });

  Future<void> writeTextFile(String sessionId, String path, String content);

  /// `terminal/*` ([method] and its params), answered only by a client that
  /// advertises `terminal`; the default refuses.
  Future<Object?> terminal(String method, Object? params) async =>
      throw AcpMethodNotSupported(method);
}
