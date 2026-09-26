/// The server's data API, for any Dart client: [HostDataLink] dials a host's
/// socket, and [DataService] answers the same requests over a store. No
/// `dart:ffi` and no Flutter, like `protocol.dart`.
///
/// A client runs a [DataService] itself only where no server can answer (the
/// desktop app's temporary fallback, and its tests); everywhere else it is
/// the server's alone.
library;

export 'src/client/host_data_link.dart';
export 'src/data/data_service.dart';
