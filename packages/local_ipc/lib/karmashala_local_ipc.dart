/// Owner-only local RPC over a **unix domain socket**, on every platform.
///
/// ## Why a socket and not a named pipe
///
/// This package used to be a Windows named pipe driven by blocking Win32 calls
/// (`ConnectNamedPipe`, `ReadFile`) on a spawned isolate. That worked, but it
/// had two costs that a socket does not:
///
/// * **It was Windows-only.** `NamedPipeRpcServer.start` threw
///   `UnsupportedError` anywhere else, so Linux and macOS were left on
///   authenticated loopback TCP — a transport any local process can connect to.
/// * **It stopped the app from exiting.** The serving isolate parks forever
///   inside a blocking FFI call, and a blocking FFI call cannot be interrupted:
///   `Isolate.kill` does not reach it, and neither does VM shutdown. Loop 48
///   measured the consequence — with the pipe running, quitting never completed
///   at all (>120 s, process still alive); with it disabled the same build quit
///   in 322 ms.
///
/// Dart's `ServerSocket`/`Socket` support `InternetAddressType.unix` on Windows
/// 10 1803+ as well as POSIX, so one async implementation now covers all three
/// platforms and the VM can shut it down like any other IO.
///
/// ## Access control
///
/// The socket carries no access control of its own. The boundary is the
/// **directory the socket sits in**, which the caller must create restricted to
/// the current user (dray's `0700` model; on Windows an explicit ACL — see
/// `restrictDirectoryToCurrentUser`). Callers are expected to authenticate on
/// top of that; the app sends its handshake bearer token in every request.
///
/// ## Framing
///
/// One request per line, one response per line, UTF-8, newline-delimited.
/// JSON never contains a raw newline, so a line is a whole message. Both
/// directions are capped at [kLocalRpcMaxBytes] so a peer cannot make the app
/// buffer without limit.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Handles one request line and returns the response line.
typedef LocalRpcHandler = FutureOr<String> Function(String request);

/// Hard cap on a single request or response, in bytes.
const int kLocalRpcMaxBytes = 1024 * 1024;

/// How long a client waits for the server to answer before giving up.
const Duration kLocalRpcTimeout = Duration(seconds: 60);

/// Whether this platform can host a unix domain socket at all.
///
/// Windows gained `AF_UNIX` in 10 1803; on an older build the bind fails and
/// the caller has to decide what to do about it, which is why this is advisory
/// rather than a guard.
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

  /// Binds a socket at [path], serving each request line with [handler].
  ///
  /// The parent directory must already exist and should already be restricted
  /// to the current user — this does not create or protect it, because "who may
  /// reach this socket" is the caller's policy, not the transport's.
  ///
  /// A socket file left behind by a process that died is removed first, but
  /// only after probing it: if something is still listening the bind is refused
  /// rather than silently stealing another instance's address.
  static Future<LocalRpcServer> bind(
    String path,
    LocalRpcHandler handler,
  ) async {
    final address = localSocketAddress(path);
    if (File(path).existsSync()) {
      if (await _isLive(address)) {
        throw StateError('Another process is already serving $path.');
      }
      // Stale node from a crash. Deleting is safe now that nothing answers.
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
    // One request per connection is all the bridge ever sends, but a client is
    // free to pipeline: each completed line is answered in turn.
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
    // `ServerSocket.close` unlinks the node itself, but a crash-safe server
    // should not depend on that having happened.
    unlink();
  }

  /// Removes the socket node **without waiting for the server to close**.
  ///
  /// Separate from [close] so a caller that must guarantee the node is gone
  /// before it suspends can say so. A shutdown step is bounded, and a bound
  /// wait that is abandoned leaves the rest of [close] running — so the delete
  /// has to happen in the synchronous prefix or it happens at an unowned
  /// moment.
  ///
  /// **Unlinking a *bound* node is allowed**, measured on Windows 2026-09-09:
  /// the file goes at once and the listening socket stays valid until [close].
  /// Idempotent, and [close] still calls it for callers that do not.
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

  /// Connects to the socket at [socketPath], sends [request], and returns the
  /// single response line.
  ///
  /// [request] must be one line — every caller sends `jsonEncode` output, which
  /// never contains a raw newline.
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
