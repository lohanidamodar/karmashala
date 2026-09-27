/// The host's wire protocol: frames, messages and their codecs, a session's
/// lifecycle and summary, and how a box's session is named at the server.
/// No `dart:io`, so a web build may import it.
library;

export 'src/protocol/box_session_ref.dart';
export 'src/protocol/frame.dart';
export 'src/protocol/host_version.dart';
export 'src/protocol/messages.dart';
export 'src/protocol/session_lifecycle.dart';
export 'src/protocol/session_summary.dart';
export 'src/protocol/wire.dart';
