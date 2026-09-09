/// The `browser_*` tools an agent sees, and their JSON schemas.
///
/// [BrowserTools] maps one MCP tool call onto [BrowserService] and renders the
/// answer the way a model reads cheapest: our sentences first, then everything
/// the page wrote inside one untrusted-content fence. It carries no MCP framing
/// — the app wires it into the control server.
library;

export 'src/application/browser_tool_schemas.dart';
export 'src/application/browser_tools.dart';
