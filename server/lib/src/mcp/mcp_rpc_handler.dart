import 'dart:convert';

import 'package:karmashala_mcp/protocol.dart';

import 'mcp_tool_relay.dart';

/// The stdio bridge's `/rpc`: `{tool, arguments, token, callerSessionId}` in,
/// `{ok, result}` or `{ok: false, error}` out — the app's wire, unchanged.
class McpRpcHandler {
  McpRpcHandler({required this.relay, this.token});

  final McpToolRelay relay;

  /// Null when no credential was published: then nobody is authorised.
  String? token;

  bool authorises(String? presented) {
    final live = token;
    return live != null && constantTimeEquals(presented, live);
  }

  /// One request line over the owner-only socket, whose body carries the token.
  Future<String> handleSocketLine(String body) async {
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      if (!authorises(payload['token'] as String?)) {
        return jsonEncode({'ok': false, 'error': 'Unauthorized.'});
      }
      return await handlePayload(payload);
    } on Object catch (error) {
      return jsonEncode({'ok': false, 'error': '$error'});
    }
  }

  /// An authorised request's answer. The caller session is the one the bridge
  /// inherited from its agent's environment, as it always was.
  Future<String> handlePayload(Map<String, dynamic> payload) async {
    try {
      final tool = payload['tool'] as String?;
      final arguments =
          (payload['arguments'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final callerSessionId = payload['callerSessionId'] as String?;
      final Object? result = tool == '__list_tools__'
          ? relay.catalogue()
          : await relay.call(tool ?? '', arguments, callerSessionId);
      return jsonEncode({'ok': true, 'result': result});
    } on Object catch (error) {
      return jsonEncode({'ok': false, 'error': '$error'});
    }
  }
}
