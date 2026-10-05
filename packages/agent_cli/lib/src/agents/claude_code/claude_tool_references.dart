/// The tools a Claude tool result's `tool_reference` blocks load (what
/// ToolSearch answers with), as one line; null when it holds none.
String? claudeLoadedToolsText(Object? content) {
  if (content is! List) return null;
  final names = [
    for (final block in content)
      if (block is Map &&
          block['type'] == 'tool_reference' &&
          block['tool_name'] is String)
        block['tool_name'] as String,
  ];
  return names.isEmpty ? null : 'Loaded tools: ${names.join(', ')}';
}
