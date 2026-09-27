/// The host's protocol and domain, with no `dart:ffi` in it. The wire itself
/// is `karmashala_host_protocol`'s (split in slice 5d); this adds the
/// server's own domain a client of it reads.
library;

export 'package:karmashala_host_protocol/protocol.dart';

export 'src/domain/age.dart';
export 'src/domain/host_session.dart';
export 'src/domain/output_backlog.dart';
export 'src/domain/registry_change.dart';
export 'src/domain/session_recorder.dart';
export 'src/domain/session_registry.dart';
export 'src/domain/write_token.dart';
export 'src/companion/companion_port_number.dart';
export 'src/pty/pty.dart';
