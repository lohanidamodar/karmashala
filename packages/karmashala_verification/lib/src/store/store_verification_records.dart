import '../domain/verification_run.dart';
import '../service/verification_records.dart';
import 'verification_dao.dart';

/// [VerificationRecords] straight over the store, for the server;
/// [onRecorded] hears each run it wrote.
class StoreVerificationRecords implements VerificationRecords {
  StoreVerificationRecords(this._dao, {this.onRecorded});

  final VerificationDao _dao;
  final void Function(VerificationRun run)? onRecorded;

  @override
  Future<VerificationRun> record(VerificationRun run) async {
    final stored = _dao.recordWhole(run);
    onRecorded?.call(stored);
    return stored;
  }
}
