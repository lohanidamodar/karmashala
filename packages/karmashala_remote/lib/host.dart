/// The desktop host's answering half: the bindings it is handed, the session
/// API built on them, and the ledger that keeps one start from becoming two.
///
/// Every binding is a callback, so nothing here reaches a database, a provider
/// or a widget — the app composes the real ones and a test passes fakes.
library;

export 'src/application/host_bindings.dart';
export 'src/application/host_session_api.dart';
export 'src/application/session_start_ledger.dart';
