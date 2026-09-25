import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';

/// The base of a run the host starts, taken with the same checkpoint service
/// the app uses, so "restore the files" works whoever fired it.
class DaemonBaseCheckpoint implements RunBaseCheckpoint {
  const DaemonBaseCheckpoint(this._service);

  final CheckpointService _service;

  @override
  Future<String?> capture(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) async {
    // `evenIfUnchanged`: undo needs a point to restore to either way.
    final checkpoint = await _service.capture(
      checkout,
      sessionId: runId,
      reason: CheckpointReason.manual,
      label: label,
      evenIfUnchanged: true,
    );
    return checkpoint?.id;
  }
}
