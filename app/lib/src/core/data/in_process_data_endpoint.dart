import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService, DataSession;
import 'package:karmashala_store/database.dart';

/// **Temporary fallback, to be deleted.** The server's own [DataService],
/// run in this process over a database this app opened, for where no server
/// answers: under `flutter test`, and a launch whose local server could not
/// be started (the host is unproven on Windows). The same handlers and rules
/// as the server — only the transport is missing. The one file under
/// `lib/` that may run the service; `direct_database_guard_test` holds it
/// there.
class InProcessDataEndpoint implements DataEndpoint {
  InProcessDataEndpoint(AppDatabase database, {DateTime Function()? clock})
    : this.over(DataService(database, clock: clock));

  InProcessDataEndpoint.over(DataService service) {
    _session = service.open((changes) {
      if (!_changes.isClosed) _changes.add(changes);
    });
  }

  late final DataSession _session;
  final _changes = StreamController<DataChanges>.broadcast(sync: true);
  final _done = Completer<void>();

  /// Answers now: the store is synchronous, so a caller can apply the answer
  /// before it returns.
  DataReply<R> sendNow<R>(DataRequest<R> request) {
    if (_done.isCompleted) {
      throw const DataRefused.unavailable('the data service is closed');
    }
    return _session.handle(request);
  }

  @override
  Future<DataReply<R>> send<R>(DataRequest<R> request) async =>
      sendNow(request);

  @override
  Stream<DataChanges> get changes => _changes.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_done.isCompleted) return;
    _session.close();
    await _changes.close();
    _done.complete();
  }
}
