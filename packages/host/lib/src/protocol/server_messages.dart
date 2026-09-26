part of 'messages.dart';

// Administering a server from its own machine (protocol 8): the paired
// devices, revoking one, and the agent CLIs it found — what
// `karmashala_host devices`, `revoke` and `agents` ask over the owner-only
// socket. One request/answer pair with a method name, because each is a small
// JSON question and none streams; the methods are [ServerMethod]'s.

/// The methods a [ServerCallMessage] may name.
abstract final class ServerMethod {
  /// `{}` → `{name, standalone, companion: {serving, port?, bind, relay?}}` —
  /// what `pair` needs to build an invite. A relay's token is never in it.
  static const String serverInfo = 'server.info';

  /// `{}` → `{devices: [PairedDeviceSummary…]}`.
  static const String devicesList = 'devices.list';

  /// `{deviceId}` → `{device: PairedDeviceSummary}`, now revoked.
  static const String devicesRevoke = 'devices.revoke';

  /// `{}` → `{agents: [installation…]}`, as recorded.
  static const String agentsList = 'agents.list';

  /// `{}` → `{agents: [installation…], summary}`, after probing again.
  static const String agentsRefresh = 'agents.refresh';
}

/// client → host: one administrative question, answered with a
/// [ServerResultMessage] under [requestId].
class ServerCallMessage extends HostMessage {
  const ServerCallMessage({
    required this.requestId,
    required this.method,
    this.arguments = const {},
  });

  final int requestId;
  final String method;
  final Map<String, Object?> arguments;

  @override
  Frame toFrame() => Frame(
    MessageType.serverCall,
    0,
    (WireWriter()..str(
          jsonEncode({
            'requestId': requestId,
            'method': method,
            'arguments': arguments,
          }),
        ))
        .take(),
  );

  static ServerCallMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'server call',
    );
    final arguments = map['arguments'];
    return ServerCallMessage(
      requestId: _required<int>(map, 'requestId'),
      method: _required<String>(map, 'method'),
      arguments: arguments == null
          ? const {}
          : _object(arguments, 'server call arguments'),
    );
  }
}

/// host → client: how the [ServerCallMessage] under [requestId] ended — its
/// [result], or the [message] it was refused with.
class ServerResultMessage extends HostMessage {
  const ServerResultMessage.success(
    this.requestId,
    Map<String, Object?> this.result,
  ) : message = null;

  const ServerResultMessage.failure(this.requestId, String this.message)
    : result = null;

  final int requestId;
  final Map<String, Object?>? result;
  final String? message;

  bool get ok => message == null;

  @override
  Frame toFrame() => Frame(
    MessageType.serverResult,
    0,
    (WireWriter()..str(
          jsonEncode({
            'requestId': requestId,
            'result': ?result,
            'message': ?message,
          }),
        ))
        .take(),
  );

  static ServerResultMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'server result',
    );
    final requestId = _required<int>(map, 'requestId');
    final message = _optional<String>(map, 'message');
    if (message != null) return ServerResultMessage.failure(requestId, message);
    final result = map['result'];
    return ServerResultMessage.success(
      requestId,
      result == null ? const {} : _object(result, 'server result body'),
    );
  }
}
