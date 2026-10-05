import '../../sessions/tool_activity.dart';

/// Claude Code's WebSearch result (its `toolUseResult`) as the links it
/// found, one per line, then what it wrote of them; null for any other
/// result. Its text form holds the links as raw JSON.
String? claudeWebSearchText(Object? result) {
  if (result is! Map || result['searchCount'] == null) return null;
  final results = result['results'];
  if (results is! List) return null;
  final links = <String>[];
  final said = <String>[];
  for (final entry in results) {
    if (entry is Map) {
      final lines = webSearchResultLines(entry['content']);
      if (lines.isNotEmpty) links.add(lines);
    } else if (entry is String && entry.trim().isNotEmpty) {
      said.add(entry.trim());
    }
  }
  final parts = [if (links.isNotEmpty) links.join('\n'), ...said];
  return parts.isEmpty ? null : parts.join('\n\n');
}
