part of '../typed_command.dart';

// The catalog a typed command is parsed against.

/// What the argument being typed is.
enum CommandArgKind {
  keyword,
  project,
  agent,
  flag,
  session,
  environment,
  option,
}

/// The dot a session row carries.
enum SessionDot { waiting, working, idle, stopped, unknown }

/// An agent the registry knows, installed anywhere or nowhere.
class CommandAgent {
  const CommandAgent({
    required this.agentId,
    required this.token,
    required this.displayName,
    this.familyName,
    this.formLabel = 'Terminal',
  });

  final String agentId;

  /// What is typed: `claude`, `codex`, `antigravity`.
  final String token;
  final String displayName;

  /// The agent whichever form it runs in — `Codex` for Codex's chat form too;
  /// null is [displayName].
  final String? familyName;

  String get family => familyName ?? displayName;

  /// `Terminal` or `Chat`.
  final String formLabel;
}

/// One agent installed in one environment.
class CommandInstallation {
  const CommandInstallation({required this.id, required this.agentId});

  final String id;
  final String agentId;
}

/// Where `open terminal` would open for one project in one environment, or why
/// it cannot.
class CommandTerminalTarget {
  const CommandTerminalTarget({
    this.profileId,
    this.workingDirectory,
    this.refusal,
  });

  final String? profileId;
  final String? workingDirectory;
  final String? refusal;
}

class CommandProject {
  const CommandProject({
    required this.id,
    required this.name,
    required this.token,
    required this.environmentId,
    this.recencyRank,
    this.waiting = false,
    this.installations = const [],
    this.defaultInstallationId,
    this.branch,
    this.terminals = const {},
    this.notGit = false,
  });

  final String id;
  final String name;
  final String token;
  final String environmentId;

  /// 0 for the project holding the most recently active session; null when it
  /// has none with a reading.
  final int? recencyRank;

  /// Whether one of its sessions is waiting on the user.
  final bool waiting;

  /// The agents installed where this project runs.
  final List<CommandInstallation> installations;

  /// What `start` uses when no agent is named: the agent of its most recent
  /// session while still installed there, else the environment's default.
  final String? defaultInstallationId;

  /// The checked-out branch, only when something already read it.
  final String? branch;

  /// Keyed by environment id.
  final Map<String, CommandTerminalTarget> terminals;

  /// Observed not to be a Git repository — so it has no worktrees.
  final bool notGit;
}

class CommandSession {
  const CommandSession({
    required this.id,
    required this.title,
    required this.token,
    required this.projectId,
    required this.projectName,
    this.agentName = '',
    this.imported = false,
    this.dot = SessionDot.unknown,
    this.ageLabel,
    this.recencyRank,
    this.stopRefusal = 'Not running, so there is nothing to interrupt.',
    this.endRefusal = 'Not running, so there is nothing to end.',
    this.forkRefusal,
    this.archiveRefusal = 'Not a session of this app, so it has no archive.',
    this.live = false,
    this.question,
    this.questionUnread = false,
    this.approval,
    this.branch,
  });

  final String id;
  final String title;
  final String token;
  final String projectId;
  final String projectName;
  final String agentName;
  final bool imported;
  final SessionDot dot;
  final String? ageLabel;
  final int? recencyRank;
  final String? stopRefusal;
  final String? endRefusal;
  final String? forkRefusal;
  final String? archiveRefusal;
  final bool live;

  /// The question it is asking, when one is open and could be read.
  final CommandQuestion? question;

  /// A question is open but has not been read yet.
  final bool questionUnread;

  /// The command approval it waits on, when this machine can answer it.
  final CommandApproval? approval;

  /// Its checkout's branch, only when something already read it.
  final String? branch;

  bool get waiting => dot == SessionDot.waiting;

  /// "Round 21 · feat/acp": the title and where it is, for a preview.
  String get named => [
    title,
    branch ?? (projectName.isEmpty ? null : projectName),
  ].nonNulls.join(' · ');
}

/// A question a session asks, as `answer` can pick from it.
class CommandQuestion {
  const CommandQuestion({
    required this.toolUseId,
    required this.options,
    this.refusal,
  });

  final String toolUseId;

  /// The option labels, in order; option 1 is the first.
  final List<String> options;

  /// Why one option cannot answer it: several questions, or several choices.
  final String? refusal;
}

/// A command approval a session waits on.
class CommandApproval {
  const CommandApproval({
    required this.subject,
    required this.folder,
    this.toolName = '',
    this.allowRefusal,
    this.denyRefusal,
  });

  /// The exact command, path or input it asks about.
  final String subject;

  /// Where it would run; empty when nothing said.
  final String folder;
  final String toolName;
  final String? allowRefusal;
  final String? denyRefusal;

  /// Whether [other] asks the very same thing in the very same folder — the
  /// only approvals ever answered together.
  bool sameAs(CommandApproval other) =>
      other.subject == subject &&
      other.folder == folder &&
      other.toolName == toolName;
}

class CommandEnvironment {
  const CommandEnvironment({
    required this.id,
    required this.token,
    required this.label,
  });

  final String id;
  final String token;

  /// `Windows`, `WSL archlinux`, `do-box`.
  final String label;
}

/// The oldest permission prompt waiting on the user.
class CommandWaiting {
  const CommandWaiting({
    required this.itemId,
    required this.sessionId,
    required this.title,
    this.imported = false,
    this.detail,
  });

  final String itemId;
  final String sessionId;
  final String title;
  final bool imported;
  final String? detail;
}

/// A conversation the session search matched, by the session it opens.
typedef ConversationMatch = ({String sessionId, String excerpt});

/// Everything the completer can suggest, read once per palette.
class CommandCatalog {
  const CommandCatalog({
    this.projects = const [],
    this.sessions = const [],
    this.environments = const [],
    this.agents = const [],
    this.oldestWaiting,
    this.searchConversations,
    this.scratchInstallation,
    this.launchInBackground = true,
  });

  final List<CommandProject> projects;

  /// The "Resume and start sessions in the background" setting: whether
  /// `resume` and `start` keep the person where they are, or open a tab.
  final bool launchInBackground;

  /// What a session with no project runs on, as the dialog would pick it;
  /// null when no agent is installed anywhere.
  final CommandInstallation? scratchInstallation;

  /// Native and imported. `stop`, `fork` and `end` take only native ones.
  final List<CommandSession> sessions;
  final List<CommandEnvironment> environments;
  final List<CommandAgent> agents;
  final CommandWaiting? oldestWaiting;

  /// What was *said*, for `resume` when no title matches the text.
  final List<ConversationMatch> Function(String query)? searchConversations;

  CommandProject? project(String id) =>
      projects.where((p) => p.id == id).firstOrNull;

  CommandEnvironment? environment(String id) =>
      environments.where((e) => e.id == id).firstOrNull;

  CommandAgent? agent(String agentId) =>
      agents.where((a) => a.agentId == agentId).firstOrNull;

  String environmentLabel(String id) => environment(id)?.label ?? id;

  String agentName(String agentId) => agent(agentId)?.displayName ?? agentId;
}
