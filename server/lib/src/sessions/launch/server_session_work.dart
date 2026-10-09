import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../acp/acp_login_required.dart';
import '../../data/session_work.dart';
import 'capacity/session_launch_gate.dart';
import 'server_session_launcher.dart';
import 'session_continuations.dart';
import '../rewind/session_rewinds.dart';

/// The session work a client asks of the server (`sessions.*`, slice 5b),
/// answered by the one launch path. A refusal is the launch's own words:
/// `notFound` for what is gone, `invalid` for what cannot be done as asked.
class ServerSessionWork implements SessionWork {
  ServerSessionWork({required this.launches, required this.continuations});

  final ServerSessionLauncher launches;
  final SessionContinuations continuations;

  /// Told before a person's End stops row [String]: what waits is cancelled.
  void Function(String sessionId)? ending;

  /// Detaches row [String] from its parent (`SessionDetacher.detach`); null
  /// where this server cannot, and the request is refused.
  Future<Object?> Function(String sessionId)? detach;

  /// Attaches row [String] under a parent (`SessionAttacher.attach`); null
  /// where this server cannot, and the request is refused.
  Future<Object?> Function(String sessionId, String parentId)? attach;

  /// Rewinds a session; null refuses `sessions.rewind`.
  SessionRewinds? rewinds;

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
        SessionCapacityRead() =>
          launches.gate?.snapshot() ?? CapacitySnapshot.empty,
        SessionWaitStartAnyway(:final ticketId) => _wait(
          ticketId,
          (gate) => gate.startAnyway(ticketId),
        ),
        SessionWaitCancel(:final ticketId) => _wait(
          ticketId,
          (gate) => gate.cancel(ticketId),
        ),
        SessionDetachRequest(:final sessionId) => await _detach(sessionId),
        SessionAttachRequest(:final sessionId, :final parentId) =>
          await _attach(sessionId, parentId),
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
        final SessionRewind r =>
          await (rewinds ??
                  (throw StateError('This server cannot rewind a session.')))
              .rewind(r),
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

  DataAck _wait(String ticketId, bool Function(SessionLaunchGate gate) act) {
    final gate = launches.gate;
    if (gate == null || !act(gate)) {
      throw const DataRefused.notFound('That launch is not waiting any more.');
    }
    return const DataAck();
  }

  Future<DataAck> _detach(String sessionId) async {
    final detach =
        this.detach ??
        (throw const DataRefused.unavailable('this server detaches nothing'));
    await detach(sessionId);
    return const DataAck();
  }

  Future<DataAck> _attach(String sessionId, String parentId) async {
    final attach =
        this.attach ??
        (throw const DataRefused.unavailable('this server attaches nothing'));
    await attach(sessionId, parentId);
    return const DataAck();
  }

  Future<DataAck> _end(String sessionId) async {
    ending?.call(sessionId);
    await launches.end(sessionId);
    return const DataAck();
  }
}
