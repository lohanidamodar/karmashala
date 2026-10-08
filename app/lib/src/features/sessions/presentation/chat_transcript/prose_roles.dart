part of '../chat_transcript.dart';

/// How the agent's words in a turn are weighted against each other.
enum AgentProse {
  /// Short narration between tool calls ("Let me check…"): drawn muted.
  quiet,

  /// The agent's last words in a finished turn that did work first.
  finalAnswer,
}

/// The longest narration that is drawn muted; longer says something.
const int kQuietNarrationChars = 240;

/// Lines of markdown that carry structure, not narration: a heading, a list,
/// a quote, a table or a fence.
final _structuredLine = RegExp(r'^\s*(?:#|[-*+]\s|\d+[.)]\s|>|\||```|~~~)');

/// Whether narration [text] is plain enough to quiet: one short paragraph of
/// at most two lines, with no heading, list, quote, table or code.
bool isQuietNarration(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.length > kQuietNarrationChars) return false;
  final lines = trimmed.split('\n');
  if (lines.length > 2) return false;
  return !lines.any(_structuredLine.hasMatch);
}

/// **Which of the agent's rows are narration and which the answer**, by index.
///
/// Narration is the agent's words with a tool call after them in the same
/// turn; it is [AgentProse.quiet] when [isQuietNarration] says so, and full
/// strength otherwise. The final answer is the last thing the agent said in
/// a turn that is over and ran a tool call first: a turn that is only an
/// answer needs nothing set apart. Rows with no entry are drawn as before.
Map<int, AgentProse> agentProse(
  List<ChatMessage> messages, {
  required bool lastTurnOver,
}) {
  final out = <int, AgentProse>{};
  var from = 0;
  while (from < messages.length) {
    var to = from + 1;
    while (to < messages.length && !_opensTurn(messages[to])) {
      to++;
    }
    final over = to < messages.length || lastTurnOver;
    var toolAfter = false;
    var toolBefore = false;
    for (var i = from; i < to; i++) {
      if (isToolRunMember(messages[i])) toolBefore = true;
    }
    int? last;
    for (var i = to - 1; i >= from; i--) {
      final message = messages[i];
      if (isToolRunMember(message)) {
        toolAfter = true;
        continue;
      }
      if (message.role != 'agent') continue;
      final (_, clean) = splitThinking(
        message.text,
        explicit: message.thinking,
      );
      if (clean.trim().isEmpty) continue;
      if (toolAfter) {
        if (isQuietNarration(clean)) out[i] = AgentProse.quiet;
      } else {
        last ??= i;
      }
    }
    if (over && toolBefore && last != null) out[last] = AgentProse.finalAnswer;
    from = to;
  }
  return out;
}
