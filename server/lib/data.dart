/// The server's data API, for any Dart client: [HostDataLink] dials a host's
/// socket, and [DataService] answers the same requests over a store. No
/// `dart:ffi` and no Flutter, like `protocol.dart`.
///
/// Only the server, and its tests, run a [DataService]; a client reaches the
/// data through [HostDataLink] and opens no store of its own.
library;

export 'src/client/host_data_link.dart';
export 'src/data/data_service.dart';
