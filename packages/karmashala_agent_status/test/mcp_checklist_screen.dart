/// The project-MCP checklist exactly as the owner met it (2026-10-17): a new
/// terminal Claude Code session in Karmakanda, whose `.mcp.json` names `dart`
/// and `marionette`. The notice wraps by word at the pane's width, leaving
/// "documentation." alone on its row — the row the approve refusal once
/// quoted as the question. Rows as Claude Code 2.1.287 draws them in a
/// ConPTY (`mcp_checklist_test.dart` in agent_cli): the marker two columns
/// in, the box after it, the submit row's words in the names' column less
/// one.
const List<String> kOwnersMcpChecklist = [
  '  2 new MCP servers found in this project',
  '  Select any you wish to enable.',
  '',
  '  MCP servers may execute code or access system resources. All tool calls '
      'require approval. Learn more in the MCP',
  '  documentation.',
  '',
  '  ❯ [✔] dart',
  '    [✔] marionette',
  '       Enable selected',
  '',
  ' Space to select · Esc to reject all',
];
