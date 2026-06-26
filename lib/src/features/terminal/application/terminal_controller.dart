import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../data/terminal_session.dart';

/// State of the optional embedded terminal.
class TerminalState {
  const TerminalState({this.lines = const [], this.running = false});
  final List<TerminalLine> lines;
  final bool running;
}

/// Drives the optional embedded terminal: starts a shell in an environment,
/// streams its output into [TerminalState], and runs typed commands.
class TerminalController extends Notifier<TerminalState> {
  TerminalSession? _session;
  StreamSubscription<TerminalLine>? _subscription;

  @override
  TerminalState build() {
    ref.onDispose(() {
      _subscription?.cancel();
      _session?.stop();
    });
    return const TerminalState();
  }

  bool get isRunning => _session != null;

  /// Starts a shell in [environment] (optionally at [workingDir]). No-op if one
  /// is already running.
  void start(ExecutionEnvironment environment, {EnvironmentPath? workingDir}) {
    if (_session != null) return;
    final runner = ref
        .read(commandRunnerFactoryProvider)
        .forEnvironment(environment);
    final request = shellLaunch(environment.kind, workingDir: workingDir);
    final session = TerminalSession(runner.start(request));
    _session = session;
    state = TerminalState(lines: state.lines, running: true);
    _subscription = session.lines.listen(
      (line) =>
          state = TerminalState(lines: [...state.lines, line], running: true),
      onDone: () {
        _session = null;
        state = TerminalState(
          lines: [...state.lines, const TerminalLine('[shell exited]')],
          running: false,
        );
      },
    );
  }

  /// Runs [command] in the shell, echoing it into the output.
  void run(String command) {
    final session = _session;
    if (session == null) return;
    state = TerminalState(
      lines: [...state.lines, TerminalLine('\$ $command')],
      running: state.running,
    );
    session.run(command);
  }

  Future<void> stop() async {
    await _session?.stop();
    _session = null;
    await _subscription?.cancel();
    state = TerminalState(lines: state.lines, running: false);
  }

  void clear() => state = TerminalState(running: state.running);
}

final terminalControllerProvider =
    NotifierProvider<TerminalController, TerminalState>(TerminalController.new);

/// Whether the optional terminal panel is visible.
class TerminalVisibleController extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void set(bool value) => state = value;
}

final terminalVisibleProvider =
    NotifierProvider<TerminalVisibleController, bool>(
      TerminalVisibleController.new,
    );
