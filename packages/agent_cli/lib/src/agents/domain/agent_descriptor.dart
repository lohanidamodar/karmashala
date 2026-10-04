import 'dart:convert';

import '../../environments/environment_kind.dart';
import '../../permissions/permission_risk.dart';
import './agent_mcp_config.dart';
import './agent_plan.dart';
import './agent_plan_approval.dart';
import './agent_question.dart';
import './agent_screen_menu.dart';
import './agent_permission_support.dart';
import './agent_skill_support.dart';
import './agent_status.dart';

part 'agent_descriptor/acp_launch_spec.dart';
part 'agent_descriptor/agent_launch_spec.dart';
part 'agent_descriptor/agent_mcp_support.dart';
part 'agent_descriptor/agent_model_support.dart';
part 'agent_descriptor/agent_prompt_support.dart';
part 'agent_descriptor/agent_resume_support.dart';

/// Where an agent keeps its per-user config and sessions.
///
/// Where, not how: how the store is laid out, and whether it can be read at
/// all, is the agent adapter's `AgentStore`. A home with no store capability
/// behind it is located and listed, and read as nothing.
class AgentStoreSpec {
  const AgentStoreSpec({
    required this.homeDirectoryName,
    this.homeVariable,
    this.folderTrust,
  });

  /// Directory name under the environment's home, e.g. `.claude`.
  final String homeDirectoryName;

  /// The variable that moves the home elsewhere when set, e.g.
  /// `CLAUDE_CONFIG_DIR`. Asked of an SSH host; see `RemoteAgentHomes`.
  final String? homeVariable;

  /// Where and how the agent remembers a folder it was told to trust, for
  /// an agent that asks before it works in a new one; null for one that
  /// does not ask, or whose record was never read.
  final AgentFolderTrustSpec? folderTrust;
}

/// How an agent's record of a trusted folder is written.
enum AgentFolderTrustFormat {
  /// `projects.<folder>.hasTrustDialogAccepted: true` in a JSON object,
  /// the folder keyed with forward slashes on every machine.
  jsonProjects,

  /// A `[projects."<folder>"]` TOML table with `trust_level = "trusted"`,
  /// the folder keyed in lower case, as a literal string, on Windows.
  tomlProjects,
}

/// Where an agent remembers the folders it was told to trust.
class AgentFolderTrustSpec {
  const AgentFolderTrustSpec({
    required this.format,
    required this.settingsFile,
  });

  final AgentFolderTrustFormat format;

  /// The file, relative to the store home: `../.claude.json` beside
  /// `~/.claude`, `config.toml` inside `~/.codex`.
  final String settingsFile;
}

/// The best status source an agent supports. The status service falls back down
/// the sources it actually has, so this is a preference, not an exclusive
/// choice.
enum AgentStatusStrategy { hooks, stateFile, terminalGrid, none }

/// Everything Karmashala needs to find, launch and observe one agent CLI.
///
/// This is data, not code — one part of the agent's `AgentAdapter`, the part
/// that says what the agent *is*. [id] is the agent's identity everywhere —
/// discovery, persistence, settings, sessions and the MCP control server all
/// key on it. A descriptor with no code beside it (`DataOnlyAgentAdapter`) is
/// a complete, usable agent.
class AgentDescriptor {
  const AgentDescriptor({
    required this.id,
    required this.displayName,
    required this.binaries,
    this.discovery = const AgentDiscoveryRules(),
    this.launch = const AgentLaunchSpec(),
    this.store,
    this.statusStrategy = AgentStatusStrategy.none,
    this.hooks,
    this.stateFile,
    this.grid = const AgentGridRules(),
    this.terminal = const AgentTerminalRules(),
    this.approval = const AgentApprovalRules(),
    this.questions,
    this.menus,
    this.attachments = const AgentAttachmentSupport.none(),
    this.imagePaste = const AgentImagePasteKey(),
    this.plan = const AgentPlanSupport.none(),
    this.planApproval,
    this.skills = const AgentSkillSupport.none(),
    this.mcpConfig = const AgentMcpConfigSpec.undeclared(),
    this.acp,
  });

  final String id;
  final String displayName;
  final AgentBinaries binaries;
  final AgentDiscoveryRules discovery;
  final AgentLaunchSpec launch;
  final AgentStoreSpec? store;
  final AgentStatusStrategy statusStrategy;
  final AgentHookSpec? hooks;
  final AgentStateFileRules? stateFile;

  /// How to read this agent's status off its own TUI. Empty for an agent whose
  /// screen we have never looked at, which resolves to `unknown` rather than a
  /// guess.
  final AgentGridRules grid;

  /// How the agent's TUI measures text and takes typed input, where that
  /// differs from a shell's.
  final AgentTerminalRules terminal;

  /// Which keys answer this agent's approval prompt, when it names any.
  ///
  /// Empty for an agent whose prompt we have never read, so an approval from it
  /// is surfaced but not answerable from the chat view — which is the honest
  /// outcome, not a gap. Pressing keys into a TUI on a guess is the one failure
  /// mode worse than making the user switch to the terminal.
  final AgentApprovalRules approval;

  /// How this agent's multiple-choice questions are read and answered, or null
  /// for an agent none of whose questions were ever measured — surfaced as a
  /// session waiting on you, and answered at the terminal.
  final AgentQuestionSupport? questions;

  /// How this agent draws the menus that exist only on its screen — folder
  /// trust, a permission prompt, an update offer — and the keys that move
  /// through them. Null for an agent whose menus were never measured: its
  /// prompts are answered with [approval]'s keys, or at the terminal.
  final AgentMenuSupport? menus;

  /// What this agent will look at when a prompt **names a file's path**.
  ///
  /// Declared data with required evidence, exactly like [AgentForkSupport], and
  /// defaulting the same conservative way. The question is narrower than "does
  /// this CLI understand pictures": Karmashala delivers a message to a running
  /// session by typing it into that session's PTY, so a launch flag the CLI
  /// has is not a door that is open once the session is up. Only a path in the
  /// prompt is.
  final AgentAttachmentSupport attachments;

  /// Which key makes this agent paste the clipboard's image, by platform.
  final AgentImagePasteKey imagePaste;

  /// **Whether this agent keeps a plan for itself, and where to read it.**
  ///
  /// Declared data with required evidence, exactly like [attachments], and
  /// defaulting the same conservative way — the reasoning is at
  /// [AgentPlanSupport]. The question is narrower than "does this CLI plan":
  /// all three of them plan somehow. It is *"does it write the plan down
  /// somewhere this app can read"*, and on 2026-09-08 that had three different
  /// answers.
  final AgentPlanSupport plan;

  /// How this agent asks to leave plan mode and carry its plan out, or null
  /// for one whose plan prompt was never read — then it is an ordinary ask.
  final AgentPlanApprovalSupport? planApproval;

  /// **Where this agent discovers user-level skills, and how that was
  /// learned.**
  ///
  /// Declared data with required evidence, exactly like [plan], and defaulting
  /// the same conservative way — the reasoning is at [AgentSkillSupport] and
  /// the install and uninstall story is the library doc above it. The question
  /// is not "does this CLI have skills": all three of them do. It is *where*,
  /// and on 2026-09-09 that had two different shapes.
  final AgentSkillSupport skills;

  /// **Where this agent reads its own MCP servers**, so the app can report what
  /// a session started in a directory would be given.
  ///
  /// Not [AgentLaunchSpec.mcp], which is the opposite direction: that one is
  /// how Karmashala adds *itself* to one launch. Undeclared by default, and an
  /// undeclared agent reads as unknown rather than as having none.
  final AgentMcpConfigSpec mcpConfig;

  /// How this agent is driven over the Agent Client Protocol, or null for an
  /// agent that is a terminal program. See [AcpLaunchSpec].
  final AcpLaunchSpec? acp;

  @override
  String toString() => 'AgentDescriptor($id)';
}
