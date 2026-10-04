import 'dart:async';
import 'dart:io' show Platform;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        SessionCommandsChanged,
        SessionConfigOptionsChanged,
        SessionModesChanged,
        SessionUsageChanged;
import 'package:karmashala_launch/karmashala_launch.dart'
    show kSessionIdEnvironmentVariable;
import 'package:karmashala_session_engine/store.dart'
    show SessionMessageDao, SessionUsageDao;

import '../checkpoints/daemon_checkpoints.dart';
import '../data/data_service.dart';
import '../status/daemon_agent_status.dart';
import 'acp_path_scope.dart';
import 'acp_runtime_host.dart';
import 'acp_session_runtime.dart';
import 'acp_native_bridge.dart';
import 'acp_terminals.dart';
import 'acp_titles.dart';
import 'acp_transport.dart';

/// What the launcher asks an ACP runtime to run: decided by the one launch
/// path, exactly as a PTY's spawn request is.
class AcpSessionStart {
  const AcpSessionStart({
    required this.sessionId,
    required this.hostSessionId,
    required this.agentId,
    required this.agentName,
    required this.spec,
    required this.executable,
    required this.arguments,
    required this.directory,
    this.environment,
    this.variables = const {},
    this.removed = const {},
    this.mcpUrl,
    this.resumeSessionId,
    this.risk,
  });

  final String sessionId;
  final String hostSessionId;
  final String agentId;
  final String agentName;
  final AcpLaunchSpec spec;
  final String executable;

  /// After [executable]: the installation's leading arguments, then the
  /// spec's.
  final List<String> arguments;
  final EnvironmentPath directory;
  final ExecutionEnvironment? environment;
  final Map<String, String> variables;
  final Set<String> removed;
  final String? mcpUrl;
  final String? resumeSessionId;
  final PermissionRisk? risk;
}

/// Builds the runtime for one start; the launcher calls `start()` on it.
typedef AcpRuntimeFactory = AcpSessionRuntime Function(AcpSessionStart start);

/// The server's runtimes: each spawned through the environment's command
/// runner, writing to the one `session_messages` table, reporting to [host].
class AcpRuntimes {
  AcpRuntimes({
    required this.messages,
    required this.host,
    required this.runnerFor,
    this.usage,
    DateTime Function()? now,
  }) : _now = now;

  final SessionMessageDao messages;

  /// Where each agent's `usage_update`s are kept; null keeps none.
  final SessionUsageDao? usage;
  final AcpRuntimeHost host;
  final CommandRunner Function(ExecutionEnvironment? environment) runnerFor;
  final DateTime Function()? _now;

  AcpSessionRuntime start(AcpSessionStart start) {
    final files = AcpPathScope.forEnvironment(
      start.environment,
      start.directory.path,
    );
    return _runtime(
      start,
      files,
      // On the session's machine, through the runner its agent runs through.
      AcpTerminals(
        start: (request) => runnerFor(start.environment).start(request),
        scope: files,
        environmentId: start.directory.environmentId,
        posix: switch (start.environment?.kind) {
          null => !Platform.isWindows,
          EnvironmentKind.windowsNative => false,
          _ => true,
        },
        gitShell: () => findGitShell(runnerFor(start.environment)),
      ),
    );
  }

  AcpSessionRuntime _runtime(
    AcpSessionStart start,
    AcpPathScope files,
    AcpTerminals terminals,
  ) => AcpSessionRuntime(
    id: start.hostSessionId,
    sessionId: start.sessionId,
    agentId: start.agentId,
    agentName: start.agentName,
    spec: start.spec,
    workingDirectory: start.directory.path,
    spawn: () async {
      // A custom agent's own variables first, so the session id and anything
      // the launcher withholds still win.
      final variables = {...start.spec.environment, ...start.variables};
      try {
        return bridgedAcpTransport(
          start.spec,
          await startAcpProcess(
            runnerFor(start.environment).start,
            CommandRequest(
              executable: start.executable,
              arguments: start.arguments,
              workingDirectory: start.directory,
              environment: variables,
              removedEnvironment: start.removed,
            ),
          ),
        );
      } on Object catch (error) {
        throw StateError(
          withoutSecrets('$error', [
            for (final MapEntry(:key, :value) in variables.entries)
              if (key != kSessionIdEnvironmentVariable) value,
          ]),
        );
      }
    },
    messages: messages,
    usage: usage,
    files: files,
    terminals: terminals,
    host: host,
    mcpUrl: start.mcpUrl,
    risk: start.risk,
    resumeSessionId: start.resumeSessionId,
    now: _now,
  );
}

/// How long a write is held for the before-turn checkpoint. Longer than the
/// hook's bound: nothing dies on the agent's side while it waits.
const Duration kAcpCheckpointHold = Duration(seconds: 5);

/// The server around a runtime: the daemon's status, the checkpoint recorder
/// and its hints, the data channel for modes, the transcripts for rows.
class ServerAcpHost extends AcpRuntimeHost {
  ServerAcpHost({
    required this.agentStatus,
    required this.checkpoints,
    required this.data,
    this.titles,
    this.hold = kAcpCheckpointHold,
    void Function(String message)? log,
  }) : _log = log;

  final DaemonAgentStatus agentStatus;
  final DaemonCheckpoints checkpoints;
  final DataService data;

  /// Where the agent's titles go; null keeps the rows' own.
  final AcpTitles? titles;
  final Duration hold;
  final void Function(String message)? _log;

  /// Set once the transcripts exist; they are built after the launcher.
  void Function(String sessionId)? transcriptsChanged;

  @override
  void status(String sessionId, AgentStatusReport report) =>
      agentStatus.report(sessionId, report);

  @override
  Future<void> checkpointSettled(String sessionId) => checkpoints.recorder
      .settled(sessionId)
      .timeout(
        hold,
        onTimeout: () => checkpoints.recorder.noteHoldExpired(sessionId),
      )
      .catchError((Object error) {
        log('holding a write of $sessionId for its checkpoint failed: $error');
      });

  @override
  void checkpointTouched(String sessionId, Iterable<String> paths) {
    var touched = false;
    for (final path in paths) {
      if (checkpoints.hints.recordPath(sessionId, path)) touched = true;
    }
    if (touched) checkpoints.recorder.noteTouched(sessionId);
  }

  @override
  void checkpointPrompt(String sessionId, String prompt) =>
      checkpoints.hints.recordPrompt(sessionId, prompt);

  @override
  void modesChanged(SessionModesChanged change) => data.announce([change]);

  @override
  void configOptionsChanged(SessionConfigOptionsChanged change) =>
      data.announce([change]);

  @override
  void usageChanged(SessionUsageChanged change) => data.announce([change]);

  @override
  void commandsChanged(SessionCommandsChanged change) =>
      data.announce([change]);

  @override
  void titleChanged(String sessionId, String title) =>
      titles?.follow(sessionId, title);

  @override
  void messagesChanged(String sessionId) => transcriptsChanged?.call(sessionId);

  @override
  void log(String message) => _log?.call('acp: $message');
}
