import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:karmashala_projects/karmashala_projects.dart'
    show environmentPathFromJson, environmentPathToJson;
import 'package:karmashala_session/launch.dart'
    show SessionSurface, SessionView;
import 'package:karmashala_session/lineage.dart'
    show HandoffSourceBrief, SessionLink;
import 'package:karmashala_session/session.dart';

import 'terminal_values.dart' show agentLaunchFromWire, agentLaunchToWire;

// Starting sessions is the server's (slice 5b): a client names what to start
// and the server writes the row, builds the command line on its own OS with
// its own tools and vault, and runs it as a terminal under the session's own
// id (`karmashala_<sessionId>`). The client attaches a pane to it.

/// What a client asks the server to start (`sessions.start`): a checkout, an
/// agent installation and the decisions a person made, by id — the row, the
/// directory, the permission mode and the command line are the server's.
final class SessionStartSpec {
  const SessionStartSpec({
    required this.repositoryId,
    required this.installationId,
    required this.title,
    this.titleTyped = false,
    this.newSession = true,
    this.surface = SessionSurface.pane,
    this.worktree = false,
    this.worktreeBranch,
    this.worktreeBase,
    this.existingWorktree,
    this.workingDirectory,
    this.additionalRepositoryIds = const [],
    this.resumeConversationId,
    this.restartSessionId,
    this.forkConversationId,
    this.prompt,
    this.systemPrompt,
    this.parentSessionId,
    this.parentLink,
    this.permissionMode,
    this.modelId,
    this.view,
    this.columns = 120,
    this.rows = 40,
  });

  final String repositoryId;
  final String installationId;
  final String title;

  /// Whether a person typed [title], so no agent title replaces it.
  final bool titleTyped;

  /// A new conversation (`SessionPurpose.newSession`) or one the agent
  /// already has (`existingSession`) — the only input to the mode's default.
  final bool newSession;
  final SessionSurface surface;

  /// A worktree of its own, on a new branch.
  final bool worktree;

  /// With [worktree]: the branch a person named, or null for the
  /// session-named one. Absent on the wire from an older client.
  final String? worktreeBranch;

  /// With [worktree]: what [worktreeBranch] starts from; null is HEAD.
  final String? worktreeBase;

  /// A worktree that already exists, joined rather than created.
  final EnvironmentPath? existingWorktree;

  /// Where to run, without claiming it is a worktree.
  final EnvironmentPath? workingDirectory;
  final List<String> additionalRepositoryIds;
  final String? resumeConversationId;

  /// A row to start a fresh conversation in, keeping the row.
  final String? restartSessionId;
  final String? forkConversationId;

  /// The opening message.
  final String? prompt;

  /// Extra system prompt as text — a handoff packet — handed to an agent that
  /// takes a file, typed into the opening message otherwise.
  final String? systemPrompt;
  final String? parentSessionId;
  final SessionLink? parentLink;

  /// The mode chosen, canonically; null follows the row, then Settings.
  final String? permissionMode;

  /// The model chosen; null leaves the row's own choice alone.
  final String? modelId;
  final SessionView? view;

  /// The size the terminal starts at; a pane that attaches resizes it.
  final int columns;
  final int rows;

  Map<String, Object?> toJson() => {
    'repositoryId': repositoryId,
    'installationId': installationId,
    'title': title,
    'titleTyped': titleTyped,
    'newSession': newSession,
    'surface': surface.name,
    'worktree': worktree,
    'worktreeBranch': ?worktreeBranch,
    'worktreeBase': ?worktreeBase,
    if (existingWorktree != null)
      'existingWorktree': environmentPathToJson(existingWorktree!),
    if (workingDirectory != null)
      'workingDirectory': environmentPathToJson(workingDirectory!),
    if (additionalRepositoryIds.isNotEmpty)
      'additionalRepositoryIds': additionalRepositoryIds,
    'resumeConversationId': ?resumeConversationId,
    'restartSessionId': ?restartSessionId,
    'forkConversationId': ?forkConversationId,
    'prompt': ?prompt,
    'systemPrompt': ?systemPrompt,
    'parentSessionId': ?parentSessionId,
    if (parentLink != null) 'parentLink': parentLink!.name,
    'permissionMode': ?permissionMode,
    'modelId': ?modelId,
    if (view != null) 'view': view!.name,
    'columns': columns,
    'rows': rows,
  };

  static SessionStartSpec fromJson(Map<String, Object?> json) {
    String? text(String key) {
      final value = json[key];
      if (value == null || value is String) return value as String?;
      throw FormatException('$key is not text');
    }

    T? named<T extends Enum>(List<T> values, String key) {
      final value = json[key];
      if (value == null) return null;
      for (final candidate in values) {
        if (candidate.name == value) return candidate;
      }
      throw FormatException('$key is not one of ${values.join(', ')}');
    }

    final extra = json['additionalRepositoryIds'];
    return SessionStartSpec(
      repositoryId: json['repositoryId']! as String,
      installationId: json['installationId']! as String,
      title: json['title']! as String,
      titleTyped: json['titleTyped'] == true,
      newSession: json['newSession'] != false,
      surface: named(SessionSurface.values, 'surface') ?? SessionSurface.pane,
      worktree: json['worktree'] == true,
      worktreeBranch: text('worktreeBranch'),
      worktreeBase: text('worktreeBase'),
      existingWorktree: json['existingWorktree'] == null
          ? null
          : environmentPathFromJson(json['existingWorktree']),
      workingDirectory: json['workingDirectory'] == null
          ? null
          : environmentPathFromJson(json['workingDirectory']),
      additionalRepositoryIds: [
        if (extra is List)
          for (final id in extra)
            if (id is String) id,
      ],
      resumeConversationId: text('resumeConversationId'),
      restartSessionId: text('restartSessionId'),
      forkConversationId: text('forkConversationId'),
      prompt: text('prompt'),
      systemPrompt: text('systemPrompt'),
      parentSessionId: text('parentSessionId'),
      parentLink: named(SessionLink.values, 'parentLink'),
      permissionMode: text('permissionMode'),
      modelId: text('modelId'),
      view: named(SessionView.values, 'view'),
      columns: (json['columns'] as int?) ?? 120,
      rows: (json['rows'] as int?) ?? 40,
    );
  }
}

/// A command a client runs in a terminal window of its own machine — the
/// external-terminal surface. Built by the server, for the server's machine.
final class ExternalTerminalCommand {
  const ExternalTerminalCommand({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    this.wslDistribution,
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final String? wslDistribution;

  Map<String, Object?> toJson() => {
    'executable': executable,
    'arguments': arguments,
    'workingDirectory': workingDirectory,
    'wslDistribution': ?wslDistribution,
  };

  static ExternalTerminalCommand fromJson(Map<String, Object?> json) =>
      ExternalTerminalCommand(
        executable: json['executable']! as String,
        arguments: [
          for (final argument in json['arguments']! as List) argument as String,
        ],
        workingDirectory: json['workingDirectory']! as String,
        wslDistribution: json['wslDistribution'] as String?,
      );
}

/// What the server started (or found already running) for a session request.
final class SessionStarted {
  const SessionStarted({
    required this.session,
    this.launch,
    this.external,
    this.adopted = false,
    this.workingDirectoryNotice,
    this.credentialNotice,
    this.depth,
  });

  /// The row as the server wrote it.
  final Session session;

  /// The agent launch the terminal runs, without its volatile half (no MCP
  /// flags, no withheld names): what a pane stores to name its session.
  final AgentPaneLaunch? launch;

  /// For the external-terminal surface: what the client opens a window on.
  final ExternalTerminalCommand? external;

  /// The session was already running here; nothing new was started.
  final bool adopted;

  /// The session started somewhere other than where it was recorded.
  final String? workingDirectoryNotice;

  /// Credential variables withheld from the agent, in a person's words.
  final String? credentialNotice;

  /// How deep the new session is in its spawn chain, when it has a parent.
  final int? depth;

  String get sessionId => session.id;

  /// The terminal session a pane attaches to — on an SSH box too: the
  /// server relays a box session started under its own id (slice 5d).
  String get hostSessionId =>
      'karmashala_${session.id}'.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  Map<String, Object?> toJson() => {
    'session': session.toJson(),
    if (launch != null) 'launch': agentLaunchToWire(launch!),
    if (external != null) 'external': external!.toJson(),
    'adopted': adopted,
    'workingDirectoryNotice': ?workingDirectoryNotice,
    'credentialNotice': ?credentialNotice,
    'depth': ?depth,
  };

  static SessionStarted fromJson(Map<String, Object?> json) => SessionStarted(
    session: Session.fromJson(
      (json['session']! as Map).cast<String, Object?>(),
    ),
    launch: json['launch'] == null
        ? null
        : agentLaunchFromWire((json['launch']! as Map).cast<String, Object?>()),
    external: json['external'] == null
        ? null
        : ExternalTerminalCommand.fromJson(
            (json['external']! as Map).cast<String, Object?>(),
          ),
    adopted: json['adopted'] == true,
    workingDirectoryNotice: json['workingDirectoryNotice'] as String?,
    credentialNotice: json['credentialNotice'] as String?,
    depth: json['depth'] as int?,
  );
}

Map<String, Object?> sourceBriefToJson(HandoffSourceBrief brief) => {
  'text': ?brief.text,
  'notWritten': ?brief.notWritten,
};

HandoffSourceBrief sourceBriefFromJson(Object? json) {
  if (json is Map && json['text'] is String) {
    return HandoffSourceBrief.written(json['text'] as String);
  }
  if (json is Map && json['notWritten'] is String) {
    return HandoffSourceBrief.notWritten(json['notWritten'] as String);
  }
  throw const FormatException('not a source brief');
}
