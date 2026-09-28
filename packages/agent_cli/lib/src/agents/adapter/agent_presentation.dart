/// Which generic glyph stands for an agent where the app draws one. A hint,
/// not an icon: the app maps it to its own icon set.
enum AgentGlyph {
  /// An assistant — the default.
  robot,

  /// A terminal program.
  terminal,
}

/// Whose brand mark stands for an agent, where the app has that mark. A hint,
/// not an image: the app maps it to the logo it ships.
enum AgentMark {
  /// Anthropic's Claude spark.
  claude,

  /// OpenAI's logo.
  openAi,

  /// Google Antigravity's logo.
  antigravity,
}

/// How an agent is drawn where its full display name is too long or too plain.
class AgentPresentation {
  const AgentPresentation({
    required this.shortName,
    this.glyph = AgentGlyph.robot,
    this.mark,
  });

  /// The display name's first word ("Claude Code" → "Claude"), with the
  /// default glyph: short enough for a trailing badge, and read from the name
  /// so it cannot drift from what the app calls the agent.
  factory AgentPresentation.of(
    String displayName, {
    AgentGlyph glyph = AgentGlyph.robot,
    AgentMark? mark,
  }) => AgentPresentation(
    shortName: displayName.split(' ').first,
    glyph: glyph,
    mark: mark,
  );

  final String shortName;
  final AgentGlyph glyph;

  /// The agent's own mark, or null where it has none and [glyph] stands in.
  final AgentMark? mark;
}
