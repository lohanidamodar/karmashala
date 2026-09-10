import 'dart:async';
import 'dart:typed_data';

/// One client's byte channel, in both directions. Bytes, not frames: an SSH
/// exec channel, a unix socket and a pipe differ only in how they arrive, which
/// is why `karmashala_host attach` can be a dumb proxy.
abstract class HostConnection {
  /// A label for logs, and for the write token's holder when a client sends no id.
  String get description;

  Stream<Uint8List> get incoming;

  void add(Uint8List bytes);

  /// Resolves when everything queued has left this process — no timer guesses.
  Future<void> flush();

  Future<void> close();

  /// Completes when the peer went away; nothing polls for it.
  Future<void> get done;
}

/// Where clients come from.
abstract class HostListener {
  Stream<HostConnection> get connections;

  /// What a client must be told to reach this listener.
  String get address;

  Future<void> close();
}

// Everything above is location-agnostic on purpose: nothing in this package may
// reach for SSH, a remote path, or `Platform.environment['SSH_*']`, or running
// the same binary on localhost becomes a rewrite instead of a second listener.
