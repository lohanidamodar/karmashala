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

/// What a turn an error ended is filed as: "Stopped: connection lost
/// mid-response" from the error's own words, else from the hook's [reason]
/// (`server_error`), else "Stopped on an error".
String stoppedOnErrorLine(List<String> evidence, {String? reason}) {
  final said = evidenceLine(evidence)
      ?.replaceFirst(RegExp(r'^API Error:\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'[.\s]+$'), '');
  final what = (said == null || said.isEmpty)
      ? reason?.replaceAll('_', ' ')
      : said;
  if (what == null || what.isEmpty) return 'Stopped on an error';
  return 'Stopped: ${what[0].toLowerCase()}${what.substring(1)}';
}
