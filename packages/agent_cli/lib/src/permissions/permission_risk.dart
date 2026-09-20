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
  readOnly(
    'Read-only',
    'Reads and proposes. Changes nothing.',
    'Read-only',
    familiarName: 'Plan',
  ),

  /// May do anything, after asking.
  ask('Ask every time', 'Prompts before edits and commands.', 'Ask'),

  /// Writes without asking; still asks before running things.
  acceptEdits(
    'Accept edits',
    'Writes without asking. Still asks before running commands.',
    'Accept edits',
    familiarName: 'Build',
  ),

  /// No routine prompts, but something other than the user still screens what
  /// runs — a classifier, or a sandbox.
  autoRun(
    'Automatic',
    'No routine prompts. A sandbox or a reviewer model screens what runs.',
    'Automatic',
    familiarName: 'Build',
  ),

  /// No prompts and nothing screening. Dangerous.
  bypass(
    'Bypass (full autonomy)',
    'No prompts and no sandbox — use with caution.',
    'Bypass',
  );

  const PermissionRisk(
    this.label,
    this.description,
    this.shortLabel, {
    this.familiarName,
  });

  final String label;
  final String description;

  /// The name that fits on a chip. [label] has room to explain itself.
  final String shortLabel;

  /// The name this rung goes by outside this app, or null where it has none.
  ///
  /// **Borrowed from jean, and only where it reads better than ours.** jean
  /// models the same modes as Plan / Build / Yolo, and two of those three names
  /// solve a problem our own labels have: the *rung* is the thing three CLIs
  /// spell three different ways, and until now it had no name a person could
  /// carry between them. Codex's read-only rung is called a sandbox, Claude's
  /// is called a permission mode, and only Antigravity's says "plan" — so a
  /// user comparing three sessions had three words for one idea.
  ///
  /// Nothing about the modes themselves changes. This is a name shown
  /// **beside** the CLI's own word, never instead of it: a person configuring
  /// Codex still needs `read-only` and `on-request`, and the evidence each
  /// value carries is untouched. Where a CLI already says the familiar word,
  /// it is not said twice — see `pairedWithFamiliarName`.
  ///
  /// Two rungs deliberately have none:
  ///
  /// * **[ask]** — jean has no equivalent. Its approval flow is a separate
  ///   axis, not a rung, so there is nothing here to borrow.
  /// * **[bypass]** — jean calls it *Yolo*, and this is the one place a
  ///   shorter, more familiar name is worse. "Bypass" says what is bypassed to
  ///   somebody who has never met the term; "Yolo" is an in-joke, and it lands
  ///   next to `--dangerously-skip-permissions` in a confirmation dialog whose
  ///   title is the label itself — "Yolo?" is a worse question than "Bypass
  ///   (full autonomy)?". Constraint 12 asks this rung to be *surfaced with a
  ///   warning*; a nickname is the opposite move.
  final String? familiarName;

  /// Architecture constraint 12: the dangerous rung is never a default and is
  /// always surfaced with a warning.
  bool get isDangerous => this == PermissionRisk.bypass;

  /// Whether this rung permits no more than [other] does.
  bool isAtMost(PermissionRisk other) => index <= other.index;

  /// The rung with the smaller reach. Permission axes are **caps**, so a
  /// selection across several of them permits the least any one of them does.
  PermissionRisk lesser(PermissionRisk other) =>
      index <= other.index ? this : other;

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

/// The rung names, as a `const` list.
///
/// The MCP tool schemas are one `const` structure built at load time, and a
/// `for` over `PermissionRisk.values` is not a constant expression. Kept beside
/// the enum, and pinned to it by a test, so the two cannot drift.
const permissionRiskNames = [
  'readOnly',
  'ask',
  'acceptEdits',
  'autoRun',
  'bypass',
];
