import 'dart:async';
import 'dart:typed_data';

/// One client's byte channel, in both directions.
///
/// Bytes, not frames: the parser is the same in every case, and what differs
/// between an SSH exec channel, a unix socket and a pipe is only how the bytes
/// arrive. That is why `karmashala_host attach` can be a dumb proxy and why the
/// end-to-end test drives the real binary over a pipe.
abstract class HostConnection {
  /// A label for logs and for the write token's holder when the client sends
  /// no id of its own.
  String get description;

  Stream<Uint8List> get incoming;

  void add(Uint8List bytes);

  /// Resolves when everything queued has left this process. The output pump
  /// counts frames and waits on this rather than guessing with a timer.
  Future<void> flush();

  Future<void> close();

  /// Completes when the peer went away. A disconnect is observed here; nothing
  /// polls for it.
  Future<void> get done;
}

/// Where clients come from.
abstract class HostListener {
  Stream<HostConnection> get connections;

  /// What a client must be told to reach this listener.
  String get address;

  Future<void> close();
}

// ---------------------------------------------------------------------------
// STAGE TWO ATTACHES HERE.
//
// Everything above this line is location-agnostic on purpose. Running the same
// binary on localhost, so the desktop becomes a client of it and sessions
// survive an app crash, is an addition at exactly two points and nothing else:
//
//   1. A second HostListener implementation. On Windows that is a named pipe
//      (`\\.\pipe\karmashala-host-<user>`) because AF_UNIX exists there but
//      Dart's ServerSocket cannot bind it; on macOS and Linux the existing
//      UnixSocketHostListener already is that implementation, pointed at
//      $XDG_RUNTIME_DIR or ~/.karmashala on the local machine.
//
//   2. A second client-side transport in the app, beside the one that runs
//      `karmashala_host attach` over an SSH exec channel: a direct connection
//      to that listener, skipping the proxy entirely. The frames are identical,
//      which is the point of `attach` being a byte proxy rather than a
//      protocol participant.
//
// Neither the protocol, the registry, the pty layer nor HostServer needs to
// know which of the two it is serving. Nothing in this package may reach for
// SSH, for a remote path, or for `Platform.environment['SSH_*']` — the moment
// something does, stage two becomes a rewrite instead of an addition.
// ---------------------------------------------------------------------------
