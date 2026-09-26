/// Where the host's socket, lock and records live — and nothing else. Its own
/// entry point because `protocol.dart` must stay free of `dart:io` and
/// `karmashala_host.dart` binds libc, and the app needs only this.
library;

export 'src/serve/host_paths.dart';
export 'src/serve/host_build.dart';
