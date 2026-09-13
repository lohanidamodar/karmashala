/// **Where an agent reads its *own* MCP servers**, so a panel can say what a
/// session started in a directory would be given.
///
/// The opposite direction from `AgentMcpSupport`, which is how Karmashala
/// *injects itself* for one launch. That one is about a command line; this one
/// is about the user's own files, which Karmashala reads and never writes.
///
/// Declared data with required evidence, exactly like `AgentHookSpec` and
/// `AgentSkillSupport`, and defaulting the same conservative way: **an agent
/// with no declaration reads as unknown, never as empty.** Codex keeps its
/// servers in TOML rather than JSON, so it is undeclared here and its panel
/// says it has not been read — a different statement from "this agent has no
/// servers".
class AgentMcpConfigSpec {
  /// The agent keeps its servers in JSON, in up to three scopes.
  ///
  /// [projectFileName] is relative to the directory the session runs in;
  /// [userFileName] is relative to the agent's **store home**, so it may walk
  /// out of it the way `AgentHookSpec.configFileName` does — Claude Code's
  /// store is `~/.claude` and its config is `~/.claude.json`.
  const AgentMcpConfigSpec.json({
    required this.projectFileName,
    required this.projectServersPath,
    required this.userFileName,
    required this.userServersPath,
    required this.evidence,
    this.perProjectKey = '',
    this.perProjectServersPath = const [],
    this.approvedKey = '',
    this.refusedKey = '',
  }) : refusal = '';

  /// Nobody has established where this agent reads its servers. The default.
  const AgentMcpConfigSpec.undeclared({this.refusal = ''})
    : projectFileName = '',
      projectServersPath = const [],
      userFileName = '',
      userServersPath = const [],
      perProjectKey = '',
      perProjectServersPath = const [],
      approvedKey = '',
      refusedKey = '',
      evidence = '';

  /// The file in the working directory, e.g. `.mcp.json`. Empty when this agent
  /// reads no project-level file.
  final String projectFileName;

  /// Where the server map sits in that file.
  final List<String> projectServersPath;

  /// The user's own file, relative to the store home — `../.claude.json`.
  final String userFileName;

  /// Where the server map sits in that file.
  final List<String> userServersPath;

  /// The key in the user file holding one entry per directory, e.g. `projects`.
  /// Its sub-key is the directory **as the agent spells it**. Empty when this
  /// agent keeps no per-directory servers.
  final String perProjectKey;

  /// Where the server map sits inside one of those entries.
  final List<String> perProjectServersPath;

  /// The per-directory key listing project-file servers the user has approved,
  /// e.g. `enabledMcpjsonServers`. Empty when this agent asks for no approval —
  /// and then a project-file server is taken at face value.
  final String approvedKey;

  /// The per-directory key listing project-file servers the user has refused.
  final String refusedKey;

  /// Where this was read off, so a future CLI version can be re-checked.
  final String evidence;

  /// Why nothing is declared, when there are words for it.
  final String refusal;

  bool get isDeclared => userFileName.isNotEmpty || projectFileName.isNotEmpty;

  /// Whether the user file has anything worth opening for this directory.
  bool get readsPerProjectServers =>
      perProjectKey.isNotEmpty && perProjectServersPath.isNotEmpty;

  /// Whether a project-file server waits for the user before it is bound.
  bool get asksApproval => approvedKey.isNotEmpty;
}
