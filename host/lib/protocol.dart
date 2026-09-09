/// The host's protocol and domain, with no `dart:ffi` anywhere in it.
///
/// The app imports *this*, never `karmashala_host.dart`: the pty layer binds
/// libc and a Flutter web build would refuse the whole package for it. Keeping
/// the split here rather than reimplementing the codec app-side is what stops
/// the two ends of the wire drifting apart.
library;

export 'src/domain/age.dart';
export 'src/domain/host_session.dart';
export 'src/domain/output_backlog.dart';
export 'src/domain/session_lifecycle.dart';
export 'src/domain/session_recorder.dart';
export 'src/domain/session_registry.dart';
export 'src/domain/write_token.dart';
export 'src/host_version.dart';
export 'src/protocol/frame.dart';
export 'src/protocol/messages.dart';
export 'src/protocol/wire.dart';
export 'src/pty/pty.dart';
