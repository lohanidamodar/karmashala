import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

/// This app's bindings answer the session list from memory; the type says
/// `FutureOr` only because the session host answers the same bindings by
/// asking the app. A test of this app's own answers reads them as they are.
extension SyncBindings on RemoteHostBindings {
  List<RemoteSessionSnapshot> listNow() =>
      listSessions() as List<RemoteSessionSnapshot>;

  RemoteSessionSnapshot? byIdNow(String sessionId) =>
      sessionById(sessionId) as RemoteSessionSnapshot?;
}
