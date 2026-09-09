import 'dart:async';

import 'package:karmashala_browser/browser.dart';

/// A scriptable [BrowserProcess]. Feed its pipes with [emitStdout] and
/// [emitStderr], end it with [complete], and observe [killed].
class FakeBrowserProcess implements BrowserProcess {
  final StreamController<String> _stdout = StreamController<String>();
  final StreamController<String> _stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();

  bool killed = false;

  void emitStdout(String line) {
    if (!_stdout.isClosed) _stdout.add(line);
  }

  void emitStderr(String line) {
    if (!_stderr.isClosed) _stderr.add(line);
  }

  /// Completes the process with [code] and closes its pipes.
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
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> kill() async {
    killed = true;
    complete(137);
  }
}

/// One spawn the launcher asked for.
class StartedProcess {
  const StartedProcess(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// A [BrowserProcessStarter] test double: records every spawn, hands back a
/// [FakeBrowserProcess] (or whatever [processFactory] builds), or throws
/// [throwError] to stand for a browser that could not be started at all.
class FakeProcessStarter {
  final List<StartedProcess> starts = [];

  Object? throwError;
  FakeBrowserProcess Function(StartedProcess start)? processFactory;

  Future<BrowserProcess> call(String executable, List<String> arguments) async {
    final start = StartedProcess(executable, arguments);
    starts.add(start);
    if (throwError != null) throw throwError!;
    return processFactory?.call(start) ?? FakeBrowserProcess();
  }
}
