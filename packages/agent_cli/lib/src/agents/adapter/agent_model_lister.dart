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
    this.runInEnvironment,
  });

  /// The host process's environment variables.
  final Map<String, String> hostEnvironment;

  final bool hostIsWindows;

  /// Runs the agent's installation in the environment being listed — this
  /// machine, or a WSL distribution of it — or null when there is none there.
  final LocalCliRun? runLocalCli;

  /// Runs a command **inside** the environment being listed and returns its
  /// stdout, when that environment is not this process's own machine (a WSL
  /// distribution); its shell expands the arguments, so one may name
  /// `$HOME`. Null on the host itself, whose files are read directly: an
  /// agent in a distribution keeps its own store there, and
  /// the host's copy describes the host's installation — another version, with
  /// another list (owner, 2026-09-30: Codex 0.154 on Windows listed five
  /// models, 0.159 in WSL eight).
  final Future<String?> Function(String executable, List<String> arguments)?
  runInEnvironment;
}

/// **How a CLI reports the models this account may use**, so the picker
/// offers what the account can actually run rather than the descriptor's
/// curated list. Null from [list] is not an empty account: the curated list
/// stands in for it.
abstract interface class AgentModelLister {
  Future<List<AgentModel>?> list(ModelListContext context);
}
