/// The host's protocol and domain, with no `dart:ffi` in it. The app imports
/// this, never `karmashala_host.dart`, which binds libc and would fail a web
/// build.
library;

export 'src/domain/age.dart';
export 'src/domain/host_session.dart';
export 'src/domain/output_backlog.dart';
export 'src/domain/registry_change.dart';
export 'src/domain/session_lifecycle.dart';
export 'src/domain/session_recorder.dart';
export 'src/domain/session_registry.dart';
export 'src/domain/write_token.dart';
export 'src/companion/companion_port_number.dart';
export 'src/host_version.dart';
export 'src/protocol/frame.dart';
export 'src/protocol/messages.dart';
export 'src/protocol/wire.dart';
export 'src/pty/pty.dart';
