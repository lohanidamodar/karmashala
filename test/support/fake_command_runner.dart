import 'dart:async';

import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_factory.dart';
import 'package:chitragupta/src/core/process/process_handle.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';
import 'package:chitragupta/src/features/ssh/data/ssh_connection_pool.dart';

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

  void emitStdout(String line) {
    if (!_stdout.isClosed) _stdout.add(line);
  }

  void emitStderr(String line) {
    if (!_stderr.isClosed) _stderr.add(line);
  }

  /// Completes the process with [code] and closes its streams.
  void complete([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
  }

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  void writeLine(String line) => written.add(line);

  @override
  Future<int> get exitCode => _exit.future;

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
  }) : _byEnvironmentId = byEnvironmentId ?? {},
       _fallback = fallback ?? FakeCommandRunner();

  final Map<String, FakeCommandRunner> _byEnvironmentId;
  final FakeCommandRunner _fallback;

  /// Fakes never open a real connection, so there is nothing to hand out.
  @override
  SshConnectionPool Function()? get sshConnections => null;

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      _byEnvironmentId[environment.id] ?? _fallback;
}
