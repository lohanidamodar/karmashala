// Messages and turns as plain text, tool names and glyphs, and the gutter.

part of '../chat_transcript.dart';

/// A message as plain text: what "Show raw" shows and "Copy turn" copies.
String rawMessageText(ChatMessage message) {
  final tool = message.tool;
  if (tool == null) return message.text;
  return [
    toolDisplayName(tool.name),
    if (tool.subject case final subject? when subject.isNotEmpty) subject,
    if (tool.output case final output? when output.isNotEmpty) output,
  ].join('\n');
}

/// The turn holding [index] as text: from the person's message that opened it
/// to the last row before their next one.
String transcriptTurnText(List<ChatMessage> messages, int index) {
  var start = index;
  while (start > 0 && messages[start].role != 'user') {
    start--;
  }
  var end = index + 1;
  while (end < messages.length && messages[end].role != 'user') {
    end++;
  }
  final parts = <String>[];
  for (var i = start; i < end; i++) {
    final message = messages[i];
    switch (message.role) {
      case 'user':
        parts.add('You:\n${splitScratchPreamble(message.text).rest}');
      case 'agent':
        final (_, clean) = splitThinking(
          message.text,
          explicit: message.thinking,
        );
        if (clean.trim().isNotEmpty) parts.add(clean.trim());
      default:
        parts.add('› ${rawMessageText(message)}');
    }
  }
  return parts.join('\n\n');
}

/// The plan each plan row replaced, by index into [messages]; a first plan
/// has no entry.
Map<int, AgentPlan> previousPlans(List<ChatMessage> messages) {
  final before = <int, AgentPlan>{};
  AgentPlan? last;
  for (var i = 0; i < messages.length; i++) {
    final plan = messages[i].tool?.plan;
    if (plan == null) continue;
    if (last != null) before[i] = last;
    last = plan;
  }
  return before;
}

/// The side gutter of the chat column at [width]: the board's 24px where the
/// pane has room for it, and less in a side-panel-narrow pane, where 48px of
/// the 240 would be a fifth of the conversation.
double chatGutterFor(double width) => width < 480 ? Insets.md : Insets.xl;

/// `mcp__server__tool` as `server · tool`; any other name as it came.
String toolDisplayName(String name) {
  if (!name.startsWith('mcp__')) return name;
  final rest = name.substring('mcp__'.length);
  final split = rest.indexOf('__');
  if (split <= 0 || split + 2 >= rest.length) return name;
  return '${rest.substring(0, split)} · ${rest.substring(split + 2)}';
}

/// Selects an appropriate category glyph for a tool name.
IconData _toolIcon(String? name) {
  final lower = name?.toLowerCase() ?? '';
  if (lower.contains('bash') ||
      lower.contains('exec') ||
      lower.contains('cmd') ||
      lower.contains('terminal')) {
    return AppIcons.terminal;
  }
  if (lower.contains('read') ||
      lower.contains('file') ||
      lower.contains('edit') ||
      lower.contains('write') ||
      lower.contains('code')) {
    return AppIcons.code;
  }
  if (lower.contains('search') ||
      lower.contains('grep') ||
      lower.contains('find')) {
    return AppIcons.magnifyingGlass;
  }
  if (lower.contains('image') ||
      lower.contains('photo') ||
      lower.contains('preview')) {
    return AppIcons.image;
  }
  return AppIcons.gearSix;
}
