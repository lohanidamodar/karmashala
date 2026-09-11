import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/browser_failure.dart';

/// The text channel a [CdpConnection] talks over. Abstracted so CDP framing —
/// where the bugs live — is testable against a scripted socket.
abstract interface class CdpSocket {
  /// Inbound frames. Closing this stream means the peer went away.
  Stream<String> get messages;

  /// Sends one frame. Throws if the socket is already gone.
  void send(String data);

  /// Closes the socket; completes once it is fully shut down.
  Future<void> close();
}

/// [CdpSocket] backed by a real `dart:io` WebSocket.
class WebSocketCdpSocket implements CdpSocket {
  WebSocketCdpSocket(WebSocket socket)
    : _socket = socket,
      messages = socket
          .map(
            (frame) =>
                frame is String ? frame : utf8.decode(frame as List<int>),
          )
          .asBroadcastStream();

  /// Connects to a target's `webSocketDebuggerUrl`.
  static Future<WebSocketCdpSocket> connect(
    String url, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Kept apart from the timeout: `.timeout()` cancels nothing, so a socket
    // that opens late must be closed rather than left holding the target.
    final pending = WebSocket.connect(url);
    try {
      final socket = await pending.timeout(timeout);
      return WebSocketCdpSocket(socket);
    } on TimeoutException catch (e) {
      unawaited(
        pending.then<void>(
          (socket) => socket.close(WebSocketStatus.goingAway, 'timed out'),
          onError: (Object _) {},
        ),
      );
      throw BrowserException(
        BrowserFailure.timeout,
        describeBrowserFailure(
          BrowserFailure.timeout,
          detail: 'the debugger socket did not accept a connection',
        ),
        cause: e,
      );
    } on Object catch (e) {
      throw BrowserException(
        BrowserFailure.targetGone,
        describeBrowserFailure(
          BrowserFailure.targetGone,
          detail: 'could not open the debugger socket',
        ),
        cause: e,
      );
    }
  }

  final WebSocket _socket;

  @override
  final Stream<String> messages;

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close() async {
    await _socket.close();
  }
}
