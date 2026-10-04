import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../acp/acp_login_required.dart';
import '../../data/session_work.dart';
import 'server_session_launcher.dart';
import 'session_continuations.dart';

/// The session work a client asks of the server (`sessions.*`, slice 5b),
/// answered by the one launch path. A refusal is the launch's own words:
/// `notFound` for what is gone, `invalid` for what cannot be done as asked.
class ServerSessionWork implements SessionWork {
  ServerSessionWork({required this.launches, required this.continuations});

  final ServerSessionLauncher launches;
  final SessionContinuations continuations;

  /// Told before a person's End stops row [String]: its queue pauses.
  void Function(String sessionId)? ending;

  @override
  Future<Object?> handle(SessionWorkRequest<Object?> request) async {
    try {
      return switch (request) {
        SessionStart(:final spec) => await launches.start(spec),
        final SessionResume r => await launches.resume(
          r.sessionId,
          restart: r.restart,
          columns: r.columns,
          rows: r.rows,
        ),
        SessionEndRequest(:final sessionId) => await _end(sessionId),
        final SessionSourceBrief r => await continuations.sourceBrief(
          r.sessionId,
          timeoutSeconds: r.timeoutSeconds,
        ),
        final SessionHandoffPreview r => await continuations.preview(
          sessionId: r.sessionId,
          targetAgentName: r.targetAgentName,
          instruction: r.instruction,
          unresolvedTasks: r.unresolved,
          isFork: r.isFork,
          sourceBrief: r.sourceBrief,
        ),
        final SessionHandoff r => await continuations.handoff(
          sessionId: r.sessionId,
          targetInstallationId: r.targetInstallationId,
          instruction: r.instruction,
          unresolvedTasks: r.unresolved,
          intoNewWorktree: r.newWorktree,
          permissionMode: r.permissionMode,
          sourceBrief: r.sourceBrief,
        ),
        final SessionSwitchAgent r => await continuations.switchAgent(
          sessionId: r.sessionId,
          targetInstallationId: r.targetInstallationId,
          instruction: r.instruction,
          permissionMode: r.permissionMode,
        ),
        final SessionFork r => await continuations.fork(
          sessionId: r.sessionId,
          instruction: r.instruction,
          unresolvedTasks: r.unresolved,
          intoNewWorktree: r.newWorktree,
          permissionMode: r.permissionMode,
          sourceBrief: r.sourceBrief,
        ),
        final SessionForkFromCheckpoint r =>
          await continuations.forkFromCheckpoint(
            sessionId: r.sessionId,
            checkpointId: r.checkpointId,
            turn: r.turn,
            instruction: r.instruction,
            newWorktree: r.newWorktree,
            confirm: r.confirm,
            preview: r.preview,
          ),
      };
    } on DataRefused {
      rethrow;
    } on AcpLoginRequired catch (login) {
      throw DataRefused(DataRefusalCode.loginRequired, login.message);
    } on LaunchTargetMissing catch (missing) {
      throw DataRefused.notFound(missing.message);
    } on StateError catch (error) {
      throw DataRefused.invalid(error.message);
    } on ArgumentError catch (error) {
      throw DataRefused.invalid('${error.message}');
    }
  }

  Future<DataAck> _end(String sessionId) async {
    ending?.call(sessionId);
    await launches.end(sessionId);
    return const DataAck();
  }
}
