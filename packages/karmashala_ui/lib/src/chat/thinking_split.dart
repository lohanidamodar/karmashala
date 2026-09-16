/// A `<thinking>` or `<thought>` block inside an agent's words — the two tags
/// the shipped agents wrap reasoning in.
final RegExp kThinkingTagPattern = RegExp(
  r'<(?:thinking|thought)>([\s\S]*?)</(?:thinking|thought)>',
);

/// The reasoning in [text] and the turn with it removed. A non-blank [explicit]
/// field wins and leaves [text] untouched; otherwise the first tag is lifted.
(String?, String) splitThinking(String text, {String? explicit}) {
  if (explicit != null && explicit.trim().isNotEmpty) {
    return (explicit.trim(), text);
  }
  final match = kThinkingTagPattern.firstMatch(text);
  if (match == null) return (null, text);
  final thinking = match.group(1)?.trim();
  final clean = (text.substring(0, match.start) + text.substring(match.end))
      .trim();
  return (thinking, clean);
}
