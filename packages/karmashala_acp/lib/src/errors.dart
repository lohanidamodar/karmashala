import 'json.dart';
import 'vocabulary.dart';

/// Anything this package throws.
sealed class AcpException implements Exception {
  const AcpException();
}

/// The other side answered a request with a JSON-RPC error.
class AcpRpcError extends AcpException {
  const AcpRpcError(this.code, this.message, {this.data});

  factory AcpRpcError.fromJson(JsonMap json) {
    final code = json.integer('code') ?? JsonRpcErrorCodes.internalError;
    final message = json.string('message') ?? 'error $code';
    final data = json['data'];
    return code == JsonRpcErrorCodes.authRequired
        ? AcpAuthenticationRequired(message, data: data)
        : AcpRpcError(code, message, data: data);
  }

  final int code;
  final String message;
  final Object? data;

  JsonMap toJson() =>
      withoutNulls({'code': code, 'message': message, 'data': data});

  @override
  String toString() => 'AcpRpcError($code): $message';
}

/// The agent refused with -32000: `authenticate` first, then retry.
final class AcpAuthenticationRequired extends AcpRpcError {
  const AcpAuthenticationRequired(String message, {super.data})
    : super(JsonRpcErrorCodes.authRequired, message);

  @override
  String toString() => 'AcpAuthenticationRequired: $message';
}

/// The agent answered `initialize` with a protocol version we do not speak.
final class AcpVersionMismatch extends AcpException {
  const AcpVersionMismatch({required this.ours, required this.theirs});

  final int ours;
  final int? theirs;

  @override
  String toString() =>
      'AcpVersionMismatch: we speak protocol $ours, the agent answered $theirs';
}

/// A client-side method this client does not offer; the agent is answered
/// with -32601.
final class AcpMethodNotSupported extends AcpException {
  const AcpMethodNotSupported(this.method);

  final String method;

  @override
  String toString() => 'AcpMethodNotSupported: $method';
}

/// The peer closed, or the agent's stream ended, with the call unanswered.
final class AcpPeerClosed extends AcpException {
  const AcpPeerClosed([this.method]);

  final String? method;

  @override
  String toString() =>
      'AcpPeerClosed${method == null ? '' : ': $method left unanswered'}';
}
