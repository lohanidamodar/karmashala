import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';

import 'transport.dart';

/// A client on a unix domain socket. The host's own listener today; the same
/// class serves the local stage unchanged (see transport.dart).
class SocketHostConnection implements HostConnection {
  SocketHostConnection(Socket socket, this.description)
    : _socket = OrderlySocket(socket),
      // A write to a peer that has gone fails later, on the socket's `done`,
      // not in [add]: handled here once, so a client that hangs up while its
      // last frames are queued (an exit sent after the final byte) is the read
      // loop's to notice, never an uncaught error in the host.
      _done = socket.done.then<void>((_) {}, onError: (Object _) {});

  final OrderlySocket _socket;
  final Future<void> _done;

  @override
  final String description;

  @override
  Stream<Uint8List> get incoming => _socket.stream;

  @override
  void add(Uint8List bytes) => _socket.add(bytes);

  @override
  Future<void> flush() => _socket.flush();

  /// Half-closes, then closes — in order on Windows, so neither side is left
  /// with a disconnect pending (orderly_close.dart).
  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _done;
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
    return _server.map(
      (socket) => SocketHostConnection(socket, 'client-${next++}'),
    );
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
  StdioHostConnection({
    Stream<List<int>>? input,
    IOSink? output,
    this.description = 'stdio',
  }) : _input = input ?? stdin,
       _output = output ?? stdout;

  final Stream<List<int>> _input;
  final IOSink _output;

  @override
  final String description;

  @override
  Stream<Uint8List> get incoming => _input.map(
    (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
  );

  @override
  void add(Uint8List bytes) => _output.add(bytes);

  @override
  Future<void> flush() => _output.flush();

  @override
  Future<void> close() => _output.close();

  @override
  Future<void> get done => _output.done;
}
