import 'package:karmashala_host_protocol/protocol.dart';

import '../acp/acp_session_runtime.dart';
import 'host_session.dart';
import 'screen_session.dart';

/// One process the registry owns under a host session id: a PTY and its
/// screen, or an agent spoken to over the Agent Client Protocol, which has no
/// terminal. What the lifecycle feed, the status reader and a close need of
/// either is here; what only a terminal has stays on [HostSession].
sealed class HostedProcess {
  const HostedProcess();

  String get id;
  DateTime get startedAt;
  SessionLifecycle get lifecycle;
  Future<SessionLifecycle> get ended;

  /// The child's pid, or 0 where the runner does not report one.
  int get pid;

  /// Somebody asked to close this while it ran (`HostSession.closeRequested`).
  bool get closeRequested;
  bool markCloseRequested();
  Future<SessionLifecycle> stopWithHost();
  Future<SessionLifecycle> terminate({int signal = 15});

  /// What a status reader and a run's tail read from.
  ScreenSession get screen;

  /// Lets go of what the process held once the registry forgets it.
  void release();
}

final class PtyProcess extends HostedProcess {
  const PtyProcess(this.session);

  final HostSession session;

  @override
  String get id => session.id;
  @override
  DateTime get startedAt => session.startedAt;
  @override
  SessionLifecycle get lifecycle => session.lifecycle;
  @override
  Future<SessionLifecycle> get ended => session.ended;
  @override
  int get pid => session.pid;
  @override
  bool get closeRequested => session.closeRequested;
  @override
  bool markCloseRequested() => session.markCloseRequested();
  @override
  Future<SessionLifecycle> stopWithHost() => session.stopWithHost();
  @override
  Future<SessionLifecycle> terminate({int signal = 15}) =>
      session.terminate(signal: signal);
  @override
  ScreenSession get screen => session;
  @override
  void release() => session.recorder?.close();
}

final class AcpProcess extends HostedProcess {
  const AcpProcess(this.runtime);

  final AcpSessionRuntime runtime;

  @override
  String get id => runtime.id;
  @override
  DateTime get startedAt => runtime.startedAt;
  @override
  SessionLifecycle get lifecycle => runtime.lifecycle;
  @override
  Future<SessionLifecycle> get ended => runtime.ended;
  @override
  int get pid => 0;
  @override
  bool get closeRequested => runtime.closeRequested;
  @override
  bool markCloseRequested() => runtime.markCloseRequested();
  @override
  Future<SessionLifecycle> stopWithHost() => runtime.stopWithHost();
  @override
  Future<SessionLifecycle> terminate({int signal = 15}) => runtime.stop();
  @override
  ScreenSession get screen => runtime;
  @override
  void release() {}
}
