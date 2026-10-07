/// The agent tools the server runs itself (slice 2b): their schemas, in the
/// order they are served, for a client that composes the whole catalogue —
/// the server's, then its own.
library;

export 'src/mcp/tools/server_tool_schemas.dart' show serverToolSchemas;
export 'src/mcp/tools/webhook_tool_set.dart' show kProposeOnlyAutomationTools;
