/// Owner-only local RPC over a unix domain socket, on every platform — Dart
/// binds `InternetAddressType.unix` on Windows 10 1803+ as well as POSIX.
///
/// The socket has no access control of its own: the boundary is the directory
/// it sits in, which the caller must restrict to the current user. Framing is
/// one UTF-8 line per message, capped at [kLocalRpcMaxBytes].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

export 'socket_location.dart';

/// Handles one request line and returns the response line.
typedef LocalRpcHandler = FutureOr<String> Function(String request);

/// Hard cap on a single request or response, in bytes.
const int kLocalRpcMaxBytes = 1024 * 1024;

/// How long a client waits for the server to answer before giving up.
const Duration kLocalRpcTimeout = Duration(seconds: 60);

/// Whether this platform can host a unix domain socket at all. Advisory: an
/// older Windows build passes this and still fails at bind.
bool get localSocketsSupported =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Builds the address for a unix socket at [path].
InternetAddress localSocketAddress(String path) =>
    InternetAddress(path, type: InternetAddressType.unix);

/// An RPC server listening on the unix socket at [path].
class LocalRpcServer {
  LocalRpcServer._(this.path, this._server, this._handler) {
    _server.listen(_accept, onError: (Object _) {});
  }

  /// The filesystem path of the socket. Published to clients by the caller.
  final String path;

  final ServerSocket _server;
  final LocalRpcHandler _handler;

  /// Binds a socket at [path], serving each request line with [handler]. The
  /// parent directory's permissions are the caller's policy, not this one's.
  ///
  /// A node left by a crash is removed first, but only after probing it: if
  /// something still answers the bind is refused rather than stealing it.
  static Future<LocalRpcServer> bind(
    String path,
    LocalRpcHandler handler,
  ) async {
    final address = localSocketAddress(path);
    if (File(path).existsSync()) {
      if (await _isLive(address)) {
        throw StateError('Another process is already serving $path.');
      }
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // Bind will fail below with a clearer error than we could raise here.
      }
    }
    final server = await ServerSocket.bind(address, 0);
    return LocalRpcServer._(path, server, handler);
  }

  /// Whether something is accepting connections at [address] right now.
  static Future<bool> _isLive(InternetAddress address) async {
    try {
      final probe = await Socket.connect(
        address,
        0,
        timeout: const Duration(milliseconds: 500),
      );
      probe.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  void _accept(Socket socket) {
    // A client may pipeline, so every completed line is answered in turn.
    final reader = _LineReader(kLocalRpcMaxBytes);
    socket.listen(
      (chunk) async {
        final List<String> lines;
        try {
          lines = reader.add(chunk);
        } on FormatException catch (error) {
          _write(socket, jsonEncode({'ok': false, 'error': '$error'}));
          await socket.close();
          return;
        }
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          String response;
          try {
            response = await _handler(line);
          } on Object catch (error) {
            response = jsonEncode({'ok': false, 'error': '$error'});
          }
          if (utf8.encode(response).length > kLocalRpcMaxBytes) {
            response = jsonEncode({
              'ok': false,
              'error': 'Response exceeds the 1 MiB limit.',
            });
          }
          _write(socket, response);
        }
      },
      onError: (Object _) => socket.destroy(),
      onDone: () => socket.destroy(),
      cancelOnError: true,
    );
  }

  void _write(Socket socket, String line) {
    try {
      socket.add(utf8.encode(line));
      socket.add(const [0x0a]);
    } on Object {
      // The peer hung up mid-answer; nothing to recover.
    }
  }

  /// Stops listening and removes the socket file.
  Future<void> close() async {
    await _server.close();
    // `ServerSocket.close` unlinks the node itself; not relying on that is free.
    unlink();
  }

  /// Removes the socket node without waiting for the server to close.
  ///
  /// Unlinking a *bound* node is allowed and immediate (Windows, 2026-09-09),
  /// so a bounded shutdown can do it in its synchronous prefix rather than
  /// behind an await it may abandon. Idempotent; [close] calls it too.
  void unlink() {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Already gone, or held; harmless either way.
    }
  }
}

/// Sends one request to a [LocalRpcServer] and returns its response.
class LocalRpcClient {
  const LocalRpcClient._();

  /// Connects to [socketPath], sends the one-line [request], and returns the
  /// single response line. Refuses a request with a newline or over the cap.
  static Future<String> call(
    String socketPath,
    String request, {
    Duration timeout = kLocalRpcTimeout,
  }) async {
    final encoded = utf8.encode(request);
    if (encoded.length > kLocalRpcMaxBytes) {
      throw ArgumentError('Request exceeds the 1 MiB limit.');
    }
    if (request.contains('\n')) {
      throw ArgumentError('Request must not contain a newline.');
    }
    final socket = await Socket.connect(
      localSocketAddress(socketPath),
      0,
      timeout: timeout,
    );
    try {
      socket.add(encoded);
      socket.add(const [0x0a]);
      await socket.flush();
      final reader = _LineReader(kLocalRpcMaxBytes);
      await for (final chunk in socket.timeout(timeout)) {
        final lines = reader.add(chunk);
        if (lines.isNotEmpty) return lines.first;
      }
      throw StateError('The server closed the connection without answering.');
    } finally {
      socket.destroy();
    }
  }
}

/// Splits a byte stream into newline-delimited UTF-8 lines, refusing to buffer
/// more than [limit] bytes for a single unterminated line.
class _LineReader {
  _LineReader(this.limit);

  final int limit;
  final List<int> _buffer = [];

  List<String> add(List<int> chunk) {
    final lines = <String>[];
    for (final byte in chunk) {
      if (byte == 0x0a) {
        lines.add(utf8.decode(_buffer, allowMalformed: true));
        _buffer.clear();
        continue;
      }
      _buffer.add(byte);
      if (_buffer.length > limit) {
        _buffer.clear();
        throw const FormatException('Message exceeds the 1 MiB limit.');
      }
    }
    return lines;
  }
}
