/// One line of an agent's own words, for a surface that has room for one.
///
/// Shared by the toast and the attention inbox so the two cannot disagree
/// about what the same event said. The toast reached this first
/// (`NotificationCoalescer`); the inbox is the panel you open *because* you
/// missed the toast, so it showing less was the wrong way round.
///
/// **Quoted in screen order and never picked apart.** For a grid-sourced
/// approval the evidence is the prompt's rendered rows, and deciding which row
/// is "the question" would be guessing at a TUI's layout — a wrong guess
/// misdescribes what the user is about to authorise. A clip at the end is
/// honest about being a clip; choosing a middle is not.
///
/// Null when the source gave nothing. Never synthesised: an absent second line
/// reads as "not recorded", which is the rule `AgentStatusReport.evidence`
/// holds itself to.
/// **Folded onto one line, and that is not the same as picking it apart.** A
/// grid row arrives already one line; a hook message does not — Claude Code's
/// `last_assistant_message` is whole paragraphs, blank lines and bullets, and a
/// toast body given those paints its first line and drops the rest. Runs of
/// whitespace become one space so the whole quote reaches the clip, which is
/// the only place a decision about what to drop belongs.
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
