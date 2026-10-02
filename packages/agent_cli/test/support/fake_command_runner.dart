import 'dart:async';

import 'package:agent_cli/src/environments/execution_environment.dart';
import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/command_runner_factory.dart';
import 'package:agent_cli/src/process/process_handle.dart';

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
    this.processFactory,
  });

  @override
  final String environmentId;

  /// Maps a request to a result. Defaults to exit 0 with empty output.
  CommandResult Function(CommandRequest request)? responder;

  /// If set, [run] throws this instead of returning a result.
  Object? throwError;

  /// Builds the [ProcessHandle] returned by [start]. Defaults to a fresh
  /// [FakeProcessHandle].
  ProcessHandle Function(CommandRequest request)? processFactory;

  /// All requests received, in order.
  final List<CommandRequest> requests = [];

  /// Requests received via [start], in order.
  final List<CommandRequest> startRequests = [];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    if (throwError != null) throw throwError!;
    return responder?.call(request) ??
        const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) async {
    startRequests.add(request);
    if (throwError != null) throw throwError!;
    return processFactory?.call(request) ?? FakeProcessHandle();
  }
}

/// A scriptable [ProcessHandle] test double. Feed stdout lines with
/// [emitStdout], inspect what was written with [written], and observe lifecycle
/// via [killed]/[complete].
class FakeProcessHandle implements ProcessHandle {
  final StreamController<String> _stdout = StreamController<String>();
  final StreamController<String> _stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();

  /// Lines written to stdin (without the trailing newline).
  final List<String> written = [];
  bool killed = false;

  /// Whether the process was asked to stop the way Ctrl-C would, rather than
  /// terminated. The two are a real difference for `simctl recordVideo`.
  bool interrupted = false;

  final StreamController<List<int>> _stdoutBytes =
      StreamController<List<int>>();

  void emitStdout(String line) {
    if (!_stdout.isClosed) _stdout.add(line);
  }

  /// Raw stdout, for the callers that read something other than text.
  void emitStdoutBytes(List<int> bytes) {
    if (!_stdoutBytes.isClosed) _stdoutBytes.add(bytes);
  }

  void emitStderr(String line) {
    if (!_stderr.isClosed) _stderr.add(line);
  }

  /// What a decoder or a broken pipe raises on the stdout stream itself.
  void emitStdoutError(Object error) {
    if (!_stdout.isClosed) _stdout.addError(error);
  }

  /// Completes the process with [code] and closes its streams.
  void complete([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_stdout.isClosed) _stdout.close();
    if (!_stdoutBytes.isClosed) _stdoutBytes.close();
    if (!_stderr.isClosed) _stderr.close();
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<List<int>> get stdoutBytes => _stdoutBytes.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  void writeLine(String line) => written.add(line);

  /// Whether stdin was closed, which is how the one-shot `ask` mode stops a
  /// CLI waiting for input that is never coming.
  bool stdinClosed = false;

  @override
  Future<void> closeStdin() async => stdinClosed = true;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> interrupt() async {
    interrupted = true;
    complete(0);
  }

  @override
  Future<void> kill() async {
    killed = true;
    complete(137);
  }
}

/// A [CommandRunnerFactory] that hands out [FakeCommandRunner]s. Returns a
/// per-environment runner when registered, otherwise [fallback].
class FakeCommandRunnerFactory implements CommandRunnerFactory {
  FakeCommandRunnerFactory({
    Map<String, FakeCommandRunner>? byEnvironmentId,
    FakeCommandRunner? fallback,
  }) : byEnvironmentId = byEnvironmentId ?? {},
       fallback = fallback ?? FakeCommandRunner();

  final Map<String, FakeCommandRunner> byEnvironmentId;
  final FakeCommandRunner fallback;

  /// A fake hands out a runner for every kind, SSH included, so a caller
  /// asking this factory must not refuse one.
  @override
  bool get canReachRemote => true;

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      byEnvironmentId[environment.id] ?? fallback;

  @override
  CommandRunner unsupported(ExecutionEnvironment environment) =>
      byEnvironmentId[environment.id] ?? fallback;

  /// This factory as the `RunnerResolver` the adapters and `CliStoreLocator`
  /// take — the seam that replaced the factory-plus-DAO trio.
  RunnerResolver get resolver =>
      (String environmentId) => byEnvironmentId[environmentId] ?? fallback;
}
