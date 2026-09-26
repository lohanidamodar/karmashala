import '../domain/verification_run.dart';

/// Where a finished gate's run is kept: the store at the server, the server's
/// data API in a client.
abstract interface class VerificationRecords {
  /// Records [run] whole — its steps and artifacts with it — and answers it
  /// as stored.
  Future<VerificationRun> record(VerificationRun run);
}
