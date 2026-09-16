/// The port a session host listens on for phones.
///
/// Here, and not beside the listener, because two packages have to agree on it
/// and only one of them may touch `dart:ffi`: the desktop reaches this through
/// `protocol.dart`, which a web build can compile, while the listener that
/// binds it lives behind `karmashala_host.dart`, which cannot. One constant is
/// what stops a deploy opening a port nothing is listening on.
library;

/// Its own, not the desktop's: a box may run both, and two listeners on one
/// port is a failure at bind time rather than a question anybody wants to
/// debug later.
const int kHostCompanionPort = 47_820;
