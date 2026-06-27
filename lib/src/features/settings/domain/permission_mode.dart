/// How much an agent is allowed to do without asking.
///
/// The safe default is [ask]. [bypass] is the dangerous "skip all permission
/// prompts" mode — it is never the default and is surfaced with a warning
/// (architecture constraint 12: do not default to dangerous permission-bypass).
enum PermissionMode {
  /// Prompt for every action (file edits and commands). Safe default.
  ask('Ask every time', 'Prompt before edits and commands.', false),

  /// Auto-approve file edits; still prompt for commands.
  acceptEdits(
    'Accept edits',
    'Auto-approve file edits; ask for commands.',
    false,
  ),

  /// Bypass all permission prompts — full autonomy. Dangerous.
  bypass(
    'Bypass (full autonomy)',
    'Skips all prompts — use with caution.',
    true,
  );

  const PermissionMode(this.label, this.description, this.isDangerous);

  final String label;
  final String description;
  final bool isDangerous;
}
