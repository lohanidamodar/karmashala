/// One line of an agent's own words, shared by the toast and the inbox. Quoted
/// in screen order, folded to one line, never picked apart; null when empty.
String? evidenceLine(List<String> evidence, {int max = 120}) {
  final quoted = evidence
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join(' · ');
  if (quoted.isEmpty) return null;
  // Runes, not code units: clipping mid-surrogate would emit a broken glyph.
  final runes = quoted.runes.toList();
  if (runes.length <= max) return quoted;
  return '${String.fromCharCodes(runes.take(max)).trimRight()}…';
}
