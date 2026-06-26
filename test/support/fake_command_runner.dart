import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_factory.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';

/// A deterministic [CommandRunner] test double.
///
/// Records every [CommandRequest] it receives and returns scripted results via
/// [responder] (or a default success), or throws [throwError] to simulate a
/// missing executable / unavailable environment.
class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner({
    this.environmentId = 'windows',
    this.responder,
    this.throwError,
  });

  @override
  final String environmentId;

  /// Maps a request to a result. Defaults to exit 0 with empty output.
  CommandResult Function(CommandRequest request)? responder;

  /// If set, [run] throws this instead of returning a result.
  Object? throwError;

  /// All requests received, in order.
  final List<CommandRequest> requests = [];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    if (throwError != null) throw throwError!;
    return responder?.call(request) ??
        const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// A [CommandRunnerFactory] that hands out [FakeCommandRunner]s. Returns a
/// per-environment runner when registered, otherwise [fallback].
class FakeCommandRunnerFactory implements CommandRunnerFactory {
  FakeCommandRunnerFactory({
    Map<String, FakeCommandRunner>? byEnvironmentId,
    FakeCommandRunner? fallback,
  }) : _byEnvironmentId = byEnvironmentId ?? {},
       _fallback = fallback ?? FakeCommandRunner();

  final Map<String, FakeCommandRunner> _byEnvironmentId;
  final FakeCommandRunner _fallback;

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      _byEnvironmentId[environment.id] ?? _fallback;
}
