/// The Agent Client Protocol from the client side: a newline-delimited
/// JSON-RPC peer, a typed facade over an agent, and the value types.
///
/// Spec: https://agentclientprotocol.com/protocol/v1/overview
library;

export 'src/client/acp_agent_client.dart';
export 'src/client/acp_client_handler.dart';
export 'src/errors.dart';
export 'src/json.dart' show JsonMap, JsonMapReads, asJsonMap;
export 'src/peer/acp_peer.dart';
export 'src/peer/peer_messages.dart';
export 'src/types/capabilities.dart';
export 'src/types/content_block.dart';
export 'src/types/enums.dart';
export 'src/types/mcp_server.dart';
export 'src/types/permission.dart';
export 'src/types/plan.dart';
export 'src/types/results.dart';
export 'src/types/session_config.dart';
export 'src/types/session_update.dart';
export 'src/types/tool_call.dart';
export 'src/types/wire_enum.dart' show WireEnum;
export 'src/vocabulary.dart';
