import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// A client on a unix domain socket. The host's own listener today; the same
/// class serves the local stage unchanged (see transport.dart).
class SocketHostConnection implements HostConnection {
  SocketHostConnection(this._socket, this.description);

  final Socket _socket;

  @override
  final String description;

  @override
  Stream<Uint8List> get incoming => _socket;

  @override
  void add(Uint8List bytes) => _socket.add(bytes);

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } on SocketException {
      // The peer hung up first; there is nothing left to close politely.
    }
    // close() only half-closes, and a client waiting for end-of-file on a
    // refusal would sit there until something else timed it out. When the host
    // is done with a connection it is done in both directions.
    _socket.destroy();
  }

  @override
  Future<void> get done => _socket.done.catchError((Object _) => _socket);
}

class UnixSocketHostListener implements HostListener {
  UnixSocketHostListener._(this._server, this.path);

  final ServerSocket _server;
  final String path;

  static Future<UnixSocketHostListener> bind(String path) async {
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    return UnixSocketHostListener._(server, path);
  }

  @override
  String get address => path;

  @override
  Stream<HostConnection> get connections {
    var next = 0;
    return _server.map((socket) => SocketHostConnection(socket, 'client-${next++}'));
  }

  @override
  Future<void> close() async {
    await _server.close();
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
}

/// stdin/stdout as one connection. This is what `karmashala_host attach`
/// bridges to, and what a test drives over a pipe.
class StdioHostConnection implements HostConnection {
  StdioHostConnection({Stream<List<int>>? input, IOSink? output, this.description = 'stdio'})
    : _input = input ?? stdin,
      _output = output ?? stdout;

  final Stream<List<int>> _input;
  final IOSink _output;

  @override
  final String description;

  @override
  Stream<Uint8List> get incoming =>
      _input.map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk));

  @override
  void add(Uint8List bytes) => _output.add(bytes);

  @override
  Future<void> flush() => _output.flush();

  @override
  Future<void> close() => _output.close();

  @override
  Future<void> get done => _output.done;
}
