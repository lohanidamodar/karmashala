/// Where the host's socket, lock and records live — and nothing else.
///
/// A third entry point beside `protocol.dart` and `karmashala_host.dart`,
/// because the app needs exactly this one thing from the host's `serve` side
/// and must not pay for the rest: `protocol.dart` is deliberately free of
/// `dart:io` so a web build can still compile it, and `karmashala_host.dart`
/// binds libc. The alternative was spelling the socket's path a second time
/// app-side, which is the drift this package exists to prevent.
library;

export 'src/serve/host_paths.dart';
