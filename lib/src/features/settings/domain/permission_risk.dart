/// How much an agent may do without asking — the **coarse, cross-agent** scale.
///
/// This is deliberately *not* the mode a user picks. Each CLI's real modes are
/// declared per agent on its descriptor (`AgentPermissionSupport`), in that
/// CLI's own vocabulary; this enum only says how permissive one of those modes
/// is, on a scale every agent can be compared on. It exists because four things
/// genuinely need a cross-agent comparison and none of them can be written per
/// agent: the handoff carry rule, the review ceiling, the danger colour, and
/// the agent-agnostic `permissionMode` argument on the MCP tools.
///
/// **Declaration order is the safety order, safest first**, and nothing else
/// defines it — [isAtMost] is an index comparison for that reason.
enum PermissionRisk {
  /// Reads and proposes; changes nothing.
  readOnly('Read-only', 'Reads and proposes. Changes nothing.', 'Read-only'),

  /// May do anything, after asking.
  ask('Ask every time', 'Prompts before edits and commands.', 'Ask'),

  /// Writes without asking; still asks before running things.
  acceptEdits(
    'Accept edits',
    'Writes without asking. Still asks before running commands.',
    'Accept edits',
  ),

  /// No routine prompts, but something other than the user still screens what
  /// runs — a classifier, or a sandbox.
  autoRun(
    'Automatic',
    'No routine prompts. A sandbox or a reviewer model screens what runs.',
    'Automatic',
  ),

  /// No prompts and nothing screening. Dangerous.
  bypass(
    'Bypass (full autonomy)',
    'No prompts and no sandbox — use with caution.',
    'Bypass',
  );

  const PermissionRisk(this.label, this.description, this.shortLabel);

  final String label;
  final String description;

  /// The name that fits on a chip. [label] has room to explain itself.
  final String shortLabel;

  /// Architecture constraint 12: the dangerous rung is never a default and is
  /// always surfaced with a warning.
  bool get isDangerous => this == PermissionRisk.bypass;

  /// Whether this rung permits no more than [other] does.
  bool isAtMost(PermissionRisk other) => index <= other.index;

  /// The rung with the smaller reach. Permission axes are **caps**, so a
  /// selection across several of them permits the least any one of them does.
  PermissionRisk lesser(PermissionRisk other) => index <= other.index ? this : other;

  /// The rung named [name], or `null`. Parsed by name rather than
  /// `values.byName`, which throws on anything it does not recognise.
  static PermissionRisk? byName(String? name) {
    if (name == null) return null;
    for (final risk in values) {
      if (risk.name == name) return risk;
    }
    return null;
  }
}
