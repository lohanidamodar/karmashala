/// Which generic glyph stands for an agent where the app draws one. A hint,
/// not an icon: the app maps it to its own icon set.
enum AgentGlyph {
  /// An assistant — the default.
  robot,

  /// A terminal program.
  terminal,

  /// A distinct generic glyph for an agent whose mark the app does not ship.
  rocket,
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
    this.iconUrl,
  });

  /// The display name's first word ("Claude Code" → "Claude"), with the
  /// default glyph: short enough for a trailing badge, and read from the name
  /// so it cannot drift from what the app calls the agent.
  factory AgentPresentation.of(
    String displayName, {
    AgentGlyph glyph = AgentGlyph.robot,
    AgentMark? mark,
    String? iconUrl,
  }) => AgentPresentation(
    shortName: displayName.split(' ').first,
    glyph: glyph,
    mark: mark,
    iconUrl: iconUrl,
  );

  final String shortName;
  final AgentGlyph glyph;

  /// The agent's own mark, or null where it has none and [glyph] stands in.
  final AgentMark? mark;

  /// Where the agent's own icon (an SVG) is published, for an agent whose
  /// mark the app does not ship — the public ACP registry names one per
  /// entry. Drawn when fetched; [mark] wins, and [glyph] stands in until then.
  final String? iconUrl;
}
