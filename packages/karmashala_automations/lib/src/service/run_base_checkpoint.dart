import 'package:agent_cli/process.dart';

/// Records the tree as it stood before an unattended run touched it — what
/// "restore the files" restores to. Keyed by the run's id, not a session's.
abstract interface class RunBaseCheckpoint {
  /// The checkpoint's id, or null when the tree matched the previous one.
  /// Throws when nothing could be recorded.
  Future<String?> capture(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  });
}
