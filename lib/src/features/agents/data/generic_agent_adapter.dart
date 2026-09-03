import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../sessions/domain/session_event_types.dart';
import '../domain/agent_adapter.dart';
import '../domain/agent_descriptor.dart';
import 'streaming_agent_session.dart';

/// Builds the command line for an agent we know nothing about beyond its
/// registry entry: its declared base arguments, then the flags it declares for
/// this permission mode, then its declared resume convention.
List<String> genericLaunchArgs(AgentLaunchSpec spec, AgentLaunch launch) => [
  ...spec.baseArguments,
  ...launch.permission.arguments,
  if (launch.resumeSessionId != null)
    ...spec.resume.argumentsFor(launch.resumeSessionId!),
];

/// Treats one stdout line as plain agent text.
///
/// This is deliberately the *whole* protocol. Guessing at a JSON shape we have
/// never seen would turn "we don't know" into a wrong answer, so a structured
/// line is passed through verbatim rather than interpreted.
List<AgentEvent> parseGenericAgentLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return const [];
  return [
    AgentEvent(SessionEventTypes.agentMessage, {
      'role': 'assistant',
      'text': trimmed,
    }),
  ];
}

/// The adapter for an agent with no protocol adapter of its own.
///
/// It is what makes a registry-only agent openable as a session: the CLI is
/// launched from its descriptor's [AgentLaunchSpec] and its output is streamed
/// as plain text. There is no rich chat — no tool calls, no status, no
/// structured errors — because there is no protocol to read. An agent that
/// wants those gets a real adapter and an `AgentKind` member.
class GenericAgentAdapter implements AgentAdapter {
  GenericAgentAdapter({
    required this.agentId,
    required this.runnerFactory,
    required this.environmentDao,
    this.launch = const AgentLaunchSpec(),
  });

  @override
  final String agentId;

  /// The descriptor's launch vocabulary, or an empty spec for an agent that is
  /// not in the registry at all (a stored installation whose entry is gone) —
  /// in which case the executable is run with no arguments.
  final AgentLaunchSpec launch;

  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environmentDao;

  @override
  AgentSession start(AgentLaunch agentLaunch) {
    final env = environmentDao.getById(agentLaunch.installation.environmentId);
    if (env == null) {
      throw StateError(
        'Unknown environment ${agentLaunch.installation.environmentId} '
        'for $agentId.',
      );
    }
    final runner = runnerFactory.forEnvironment(env);
    final request = CommandRequest(
      executable: agentLaunch.installation.executable.path,
      arguments: genericLaunchArgs(launch, agentLaunch),
      workingDirectory: agentLaunch.workingDirectory,
    );
    return GenericAgentSession(runner.start(request));
  }
}

/// A live run of an agent with no protocol. Transport is shared via
/// [StreamingAgentSession].
class GenericAgentSession extends StreamingAgentSession {
  GenericAgentSession(super.handle);

  @override
  List<AgentEvent> parseLine(String line) => parseGenericAgentLine(line);

  @override
  String encodeUserMessage(String message) => message;
}
