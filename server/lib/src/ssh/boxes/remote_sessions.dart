import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host_protocol/protocol.dart';

import '../../domain/screen_session.dart';

/// A session on an SSH box whose screen the server keeps a copy of (slice
/// 5d): read like one of its own — a title, a folder, OSC 133, an agent's
/// status, a run's tail. Its process and exit are the box's.
abstract interface class RemoteSession implements ScreenSession {
  String get hostId;

  /// How a client names it at the server: `ssh:<hostId>/<id>`.
  String get ref;

  /// Fires on each chunk of output from now on.
  Stream<void> get output;

  /// Types [bytes] as the server itself; false when it cannot.
  bool type(List<int> bytes);
}

/// A box that cannot be used right now, in a person's words.
class RemoteSessionRefused implements Exception {
  const RemoteSessionRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// **Sessions on SSH boxes, as the rest of the server uses them** (slice 5d):
/// terminals, agent launches, a worktree's setup and a Flutter run open here
/// when their environment is a box. No SSH is in the interface — the ssh
/// domain deploys the host there, links to it and keeps the copies.
abstract interface class RemoteSessions {
  /// Whether [environment] is a box this server starts sessions on.
  bool reaches(ExecutionEnvironment environment);

  /// Starts [sessionId] on the box [environment] names — [argv], or the box
  /// user's login shell when null — and keeps its screen; `adopted` when the
  /// box already ran it. Throws [RemoteSessionRefused] in words.
  Future<({RemoteSession session, bool adopted})> open(
    ExecutionEnvironment environment, {
    required String sessionId,
    List<String>? argv,
    String? workingDirectory,
    Map<String, String> variables = const {},
    Set<String> removedVariables = const {},
    required int columns,
    required int rows,
  });

  /// The session started on a box under [sessionId], or null.
  RemoteSession? byId(String sessionId);

  /// Every box session the server keeps a copy of, running or ended.
  Iterable<RemoteSession> get sessions;

  /// Ends the box session started under [sessionId] for good; its exit code,
  /// when it had one. Throws [RemoteSessionRefused].
  Future<int?> close(String sessionId);
}

/// The one side of a client connection the relay needs (`HostServer`'s).
abstract interface class BoxRelayPeer {
  String get clientId;
  bool get hungUp;
  int nextRef();
  DateTime now();
  void send(HostMessage message);

  /// Paces a stream to this client's link, as its own sessions' output is.
  void pace(StreamSubscription<Object?> subscription);

  /// Hangs this client up: its pane dials again.
  void hangUp();
}

/// A client's attachments to box sessions, relayed by ref.
abstract interface class BoxRelayClient {
  /// Whether [ref] is one of this client's relayed attachments.
  bool holds(int ref);

  void attach(AttachMessage message);
  Future<void> close(CloseMessage message);
  void input(InputMessage message);
  void resize(ResizeMessage message);
  void claim(ClaimMessage message);
  void release(ReleaseMessage message);
  Future<void> detach(int ref);

  /// The client went: every attachment stops, its write rights are freed.
  Future<void> dispose();
}

/// **The frame relay** `HostServer` hands a box's sessions to: a client
/// attaches to `ssh:<hostId>/<sessionId>` (or a box session's own id) at its
/// own server, and the box host's frames are relayed to it by ref.
abstract interface class BoxRelay {
  /// Whether [sessionId] names a box session this relay reaches.
  bool relays(String sessionId);

  BoxRelayClient clientFor(BoxRelayPeer peer);
}
