import 'dart:async';

import 'package:agent_cli/descriptors.dart'
    show AcpLaunchSpec, AgentQuestionSet, AgentStatusReport, PermissionRisk;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionConfigOptionsChanged, SessionModesChanged, SessionUsageChanged;
import 'package:karmashala_host/src/acp/acp_path_scope.dart';
import 'package:karmashala_host/src/acp/acp_runtime_host.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/acp/acp_terminals.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:karmashala_session_engine/store.dart'
    show SessionMessageDao, SessionUsageDao;
import 'package:karmashala_store/database.dart';

/// Everything a runtime told its server, kept for assertions.
class RecordingHost extends AcpRuntimeHost {
  final statuses = <AgentStatusReport>[];
  final touched = <String>[];
  final prompts = <String>[];
  final modes = <SessionModesChanged>[];
  final configOptions = <SessionConfigOptionsChanged>[];
  final usage = <SessionUsageChanged>[];
  var messagesChangedCount = 0;
  final logged = <String>[];

  /// What a write waits on; null answers at once.
  Completer<void>? hold;
  var settledCalls = 0;

  @override
  void status(
    String sessionId,
    AgentStatusReport report, {
    AgentQuestionSet? question,
  }) => statuses.add(report);

  @override
  Future<void> checkpointSettled(String sessionId) {
    settledCalls++;
    return hold?.future ?? Future.value();
  }

  @override
  void checkpointTouched(String sessionId, Iterable<String> paths) =>
      touched.addAll(paths);

  @override
  void checkpointPrompt(String sessionId, String prompt) => prompts.add(prompt);

  @override
  void modesChanged(SessionModesChanged change) => modes.add(change);

  @override
  void configOptionsChanged(SessionConfigOptionsChanged change) =>
      configOptions.add(change);

  @override
  void usageChanged(SessionUsageChanged change) => usage.add(change);

  @override
  void messagesChanged(String sessionId) => messagesChangedCount++;

  @override
  void log(String message) => logged.add(message);
}

/// A runtime wired to [agent] over its in-memory streams: no process runs.
/// [exit] is the process exit a test completes; [agent] is closed on kill.
class FakeAcpProcess {
  FakeAcpProcess(this.agent, {this.errorLines});

  final FakeAcpAgent agent;

  /// What the agent writes to stderr; none when null.
  final Stream<String>? errorLines;
  final exit = Completer<int>();
  var killed = false;

  Future<AcpTransport> spawn() async => AcpTransport.streams(
    output: agent.toClient,
    input: agent.fromClient,
    exitCode: exit.future,
    errorLines: errorLines,
    kill: () async {
      killed = true;
      if (!exit.isCompleted) exit.complete(137);
      await agent.close();
    },
  );

  /// The process died with [code]: its exit, then its streams end.
  Future<void> die(int code) async {
    if (!exit.isCompleted) exit.complete(code);
    await agent.close();
  }
}

AcpSessionRuntime runtimeOver(
  FakeAcpProcess process, {
  required AppDatabase database,
  required String workingDirectory,
  AcpRuntimeHost? host,
  AcpPathScope? files,
  String sessionId = 's1',
  String agentId = 'claude-acp',
  AcpLaunchSpec spec = const AcpLaunchSpec(),
  String? mcpUrl,
  PermissionRisk? risk,
  String? resumeSessionId,
  DateTime Function()? now,
  Duration coalesce = const Duration(milliseconds: 20),
  Duration stopPatience = const Duration(milliseconds: 200),
  AcpTerminals? terminals,
}) {
  var ids = 0;
  return AcpSessionRuntime(
    id: 'karmashala_$sessionId',
    sessionId: sessionId,
    agentId: agentId,
    agentName: 'Fake agent',
    spec: spec,
    workingDirectory: workingDirectory,
    spawn: process.spawn,
    messages: SessionMessageDao(database),
    usage: SessionUsageDao(database),
    files: files,
    host: host ?? RecordingHost(),
    mcpUrl: mcpUrl,
    risk: risk,
    resumeSessionId: resumeSessionId,
    newId: () => 'm${++ids}',
    now: now,
    coalesce: coalesce,
    stopPatience: stopPatience,
    terminals: terminals,
    terminalRefresh: const Duration(milliseconds: 20),
  );
}

/// Lets queued microtasks and short timers run.
Future<void> pump([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> settle(Duration duration) => Future<void>.delayed(duration);
