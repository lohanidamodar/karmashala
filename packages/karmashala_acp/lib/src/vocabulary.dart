/// Every ACP name this package hard-codes, as const lists so that
/// `tool/acp_schema_check.dart` and the tests read the same ones the types do.
///
/// Spec: https://agentclientprotocol.com/protocol/v1/overview
abstract final class AcpVocabulary {
  /// The protocol version this client speaks, and the only one it accepts.
  static const protocolVersion = 1;

  /// Methods the client calls on the agent.
  static const agentMethods = [
    AcpMethods.initialize,
    AcpMethods.authenticate,
    AcpMethods.sessionNew,
    AcpMethods.sessionLoad,
    AcpMethods.sessionPrompt,
    AcpMethods.sessionCancel,
    AcpMethods.sessionSetMode,
    AcpMethods.sessionSetConfigOption,
  ];

  /// Methods the agent calls on the client, and its one notification.
  static const clientMethods = [
    AcpMethods.sessionUpdate,
    AcpMethods.sessionRequestPermission,
    AcpMethods.fsReadTextFile,
    AcpMethods.fsWriteTextFile,
  ];

  /// Transport-level methods either side may send.
  static const transportMethods = [AcpMethods.cancelRequest];

  static const sessionUpdates = [
    'user_message_chunk',
    'agent_message_chunk',
    'agent_thought_chunk',
    'tool_call',
    'tool_call_update',
    'plan',
    'available_commands_update',
    'current_mode_update',
    'config_option_update',
    'session_info_update',
    'usage_update',
  ];

  static const stopReasons = [
    'end_turn',
    'max_tokens',
    'max_turn_requests',
    'refusal',
    'cancelled',
  ];

  static const toolKinds = [
    'read',
    'edit',
    'delete',
    'move',
    'search',
    'execute',
    'think',
    'fetch',
    'switch_mode',
    'other',
  ];

  static const toolCallStatuses = [
    'pending',
    'in_progress',
    'completed',
    'failed',
  ];

  static const permissionOptionKinds = [
    'allow_once',
    'allow_always',
    'reject_once',
    'reject_always',
  ];

  static const planEntryPriorities = ['high', 'medium', 'low'];

  static const planEntryStatuses = ['pending', 'in_progress', 'completed'];

  static const contentBlockTypes = [
    'text',
    'image',
    'audio',
    'resource_link',
    'resource',
  ];

  static const toolCallContentTypes = ['content', 'diff', 'terminal'];

  static const permissionOutcomes = ['selected', 'cancelled'];

  static const errorCodes = [
    JsonRpcErrorCodes.parseError,
    JsonRpcErrorCodes.invalidRequest,
    JsonRpcErrorCodes.methodNotFound,
    JsonRpcErrorCodes.invalidParams,
    JsonRpcErrorCodes.internalError,
    JsonRpcErrorCodes.requestCancelled,
    JsonRpcErrorCodes.authRequired,
    JsonRpcErrorCodes.resourceNotFound,
  ];
}

/// ACP method names.
abstract final class AcpMethods {
  static const initialize = 'initialize';
  static const authenticate = 'authenticate';
  static const sessionNew = 'session/new';
  static const sessionLoad = 'session/load';
  static const sessionPrompt = 'session/prompt';
  static const sessionCancel = 'session/cancel';
  static const sessionSetMode = 'session/set_mode';
  static const sessionSetConfigOption = 'session/set_config_option';
  static const sessionUpdate = 'session/update';
  static const sessionRequestPermission = 'session/request_permission';
  static const fsReadTextFile = 'fs/read_text_file';
  static const fsWriteTextFile = 'fs/write_text_file';
  static const cancelRequest = r'$/cancel_request';
}

/// JSON-RPC error codes: the standard five plus ACP's own.
abstract final class JsonRpcErrorCodes {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;
  static const requestCancelled = -32800;
  static const authRequired = -32000;
  static const resourceNotFound = -32002;
}
