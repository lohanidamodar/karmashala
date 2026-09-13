/// **The install and uninstall story for agent skills**, decided before the
/// first skill was written, because writing files into somebody's agent
/// configuration is the act `AgentHookInstaller` already had to get right.
///
/// 1. **A fixed path and constant bytes.** One directory per skill under the
///    CLI's own skills root, named `karmashala-*`, holding a `SKILL.md` whose
///    text is generated from this app's own tables. Nothing in it varies with
///    the launch, so a re-install writes nothing and a diff against it means
///    the app changed.
/// 2. **Per agent that is actually there.** A skill is installed into an
///    agent's store only when that agent has a home in that environment and
///    declares a skills root here. An agent with no [AgentSkillSupport] gets
///    nothing written and its [AgentSkillSupport.refusal] says why.
/// 3. **Removed by the same code that wrote it.** Uninstall deletes exactly the
///    directories carrying `karmashalaSkillMarker` and touches nothing else, so
///    a user's own skill that collides by name survives.
/// 4. **Nothing is retired at shutdown.** `AgentHookInstaller.retireEndpoint`
///    exists because a port and a token die with the process; a skill has no
///    volatile half, and taking constant bytes out on quit to put identical
///    ones back on the next start is the race that made them constant. A skill
///    left behind names tools that a stopped app is not serving, which the
///    bodies say out loud rather than leaving to be discovered.
/// 5. **User level, not project level.** Karmashala starts sessions in
///    arbitrary checkouts, most of them worktrees it made itself. A
///    project-level install would write into every one of them, show up in the
///    user's `git status`, and be committed by accident; the tools are served
///    by one app for every project, so the teaching belongs to the machine.
library;

/// Where one agent CLI discovers **user-level** skills, and how that was
/// learned.
///
/// Declared data with required evidence, exactly like `AgentAttachmentSupport`
/// and `AgentPlanSupport`, and defaulting the same conservative way. The
/// asymmetry is the one those two argue: a skill we do not ship costs a slash
/// command nobody knew about; a directory written where a CLI never looks is
/// litter under a name only this app knows, in a folder the user did not ask
/// us to touch.
class AgentSkillSupport {
  /// This agent reads skills from [directorySegments] under the user's home.
  ///
  /// **Home-relative, not store-relative**, and that is not a stylistic
  /// choice: Claude Code and Codex keep skills inside the store home they
  /// already declare, and Antigravity keeps its sessions in
  /// `.gemini/antigravity-cli` and its skills in `.gemini/config`. Deriving
  /// one from the other would have written ours where `agy` never looks.
  ///
  /// [evidence] is where the path was read off, so a future CLI version can be
  /// re-checked rather than trusted because it is written down.
  const AgentSkillSupport.homeDirectory(
    this.directorySegments, {
    required this.evidence,
    this.projectDirectorySegments = const [],
  }) : refusal = '';

  /// Nothing may be installed for this agent. The default, and the answer for
  /// a CLI whose skill support nobody has established.
  ///
  /// [refusal] is the sentence Settings shows in place of a count; it is the
  /// host's words because only the host has ever looked at this CLI.
  const AgentSkillSupport.none({this.refusal = ''})
    : directorySegments = const [],
      projectDirectorySegments = const [],
      evidence = '';

  /// The skills root, split so no separator has to be guessed for a Windows
  /// path, a POSIX path or a `\\wsl.localhost` UNC share.
  final List<String> directorySegments;

  /// Where the same agent also discovers skills **inside a checkout**, relative
  /// to its root. Read but never written: rule 5 above is why nothing is
  /// installed here.
  final List<String> projectDirectorySegments;

  /// Empty exactly when nothing is installed.
  final String evidence;

  /// Why nothing is installed, when there are words for it.
  final String refusal;

  bool get isSupported => directorySegments.isNotEmpty;
}
