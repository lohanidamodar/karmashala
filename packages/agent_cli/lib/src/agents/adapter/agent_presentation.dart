/// Which generic glyph stands for an agent where the app draws one. A hint,
/// not an icon: the app maps it to its own icon set.
enum AgentGlyph {
  /// An assistant — the default.
  robot,

  /// A terminal program.
  terminal,
}

/// How an agent is drawn where its full display name is too long or too plain.
class AgentPresentation {
  const AgentPresentation({
    required this.shortName,
    this.glyph = AgentGlyph.robot,
  });

  /// The display name's first word ("Claude Code" → "Claude"), with the
  /// default glyph: short enough for a trailing badge, and read from the name
  /// so it cannot drift from what the app calls the agent.
  factory AgentPresentation.of(
    String displayName, {
    AgentGlyph glyph = AgentGlyph.robot,
  }) =>
      AgentPresentation(shortName: displayName.split(' ').first, glyph: glyph);

  final String shortName;
  final AgentGlyph glyph;
}
