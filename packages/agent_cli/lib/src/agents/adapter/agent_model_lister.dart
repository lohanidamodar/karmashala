import '../domain/agent_descriptor.dart';

/// Runs this machine's installation of the agent with [arguments] and returns
/// its stdout, or null when it failed or there is no installation here.
typedef LocalCliRun =
    Future<String?> Function(
      List<String> arguments, {
      String? stdinText,
      Duration timeout,
    });

/// What a model listing may need from the host.
class ModelListContext {
  const ModelListContext({
    required this.hostEnvironment,
    required this.hostIsWindows,
    this.runLocalCli,
  });

  /// The host process's environment variables.
  final Map<String, String> hostEnvironment;

  final bool hostIsWindows;

  /// Runs the agent's installation on this machine, or null when there is
  /// none here.
  final LocalCliRun? runLocalCli;
}

/// **How a CLI reports the models this account may use**, so the picker
/// offers what the account can actually run rather than the descriptor's
/// curated list. Null from [list] is not an empty account: the curated list
/// stands in for it.
abstract interface class AgentModelLister {
  Future<List<AgentModel>?> list(ModelListContext context);
}
