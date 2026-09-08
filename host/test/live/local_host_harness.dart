import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// A real `karmashala_host serve` on this machine, in a home of its own.
///
/// Its own `USERPROFILE`/`HOME` so a test never touches a host a person is
/// using, and started rather than slept for: the daemon says where it bound and
/// [start] waits on that line. If it exits first the failure quotes what it
/// said, because "another host is already running" is the one that costs an
/// hour.
class LocalHost {
  LocalHost._(this.process, this.paths, this.greeting);

  final Process process;
  final HostPaths paths;

  /// Everything the daemon printed before it was ready, including which pty
  /// layer it measured and how many sessions it restored.
  final String greeting;

  String get socketPath => paths.socketPath;

  static Future<LocalHost> start(Directory home) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/karmashala_host.dart', 'serve'],
      environment: {'USERPROFILE': home.path, 'HOME': home.path},
      workingDirectory: Directory.current.path,
    );
    final ready = Completer<String>();
    final said = StringBuffer();
    process.stdout.transform(utf8.decoder).listen((text) {
      said.write(text);
      if (said.toString().contains('restored ') && !ready.isCompleted) {
        ready.complete(said.toString());
      }
    });
    process.stderr.transform(utf8.decoder).listen(said.write);
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('serve exited $code saying:\n$said'));
        }
      }),
    );
    final greeting = await ready.future.timeout(const Duration(seconds: 90));
    return LocalHost._(process, HostPaths(Directory('${home.path}/.karmashala')), greeting);
  }

  /// Kills the daemon the way the operating system would if the machine had
  /// gone down under it: no chance to write anything, so every session it held
  /// is left recorded as running.
  Future<void> kill() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 20), onTimeout: () => -1);
  }
}

/// The protocol over a plain socket — the local transport, with no `attach`
/// process in between. The frames are the ones the SSH path sends, which is the
/// point of `attach` being a byte proxy.
class LocalHostClient {
  LocalHostClient._(this._socket, this.clientId);

  final Socket _socket;
  final String clientId;
  final _parser = FrameParser();
  final _messages = StreamController<HostMessage>.broadcast();

  /// Answers that arrived before anybody asked for them. The host sends
  /// `attached` and `exited` back to back for a session that has already ended,
  /// and a broadcast stream drops whatever nobody was listening for yet.
  final _pending = <HostMessage>[];
  final _seen = StringBuffer();
  var _requestId = 0;

  static Future<LocalHostClient> connect(String path, String clientId) async {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final client = LocalHostClient._(socket, clientId);
    socket.listen(client._onBytes, onError: (Object _) {}, cancelOnError: true);
    client.send(HelloMessage(requestId: client.nextId(), clientId: clientId));
    return client;
  }

  int nextId() => ++_requestId;

  void send(HostMessage message) => _socket.add(message.toFrame().encode());

  /// One line into the session, the way a person would type it.
  void type(int sessionRef, String line) =>
      send(InputMessage(sessionRef, Uint8List.fromList(utf8.encode('$line\r\n'))));

  void _onBytes(Uint8List chunk) {
    for (final frame in _parser.add(chunk)) {
      final message = decodeMessage(frame);
      if (message is OutputMessage) {
        _seen.write(utf8.decode(message.bytes, allowMalformed: true));
        _check();
      } else {
        _pending.add(message);
      }
      _messages.add(message);
    }
  }

  Future<T> expect<T extends HostMessage>({
    Duration within = const Duration(seconds: 30),
  }) async {
    final buffered = _pending.indexWhere((m) => m is T);
    if (buffered >= 0) return _pending.removeAt(buffered) as T;
    final message = await _messages.stream.where((m) => m is T).first.timeout(within);
    _pending.remove(message);
    return message as T;
  }

  String tail(int n) {
    final s = _seen.toString();
    return s.length <= n ? s : s.substring(s.length - n);
  }

  String? _wanted;
  Completer<bool>? _waiting;

  /// Waits for a substring by counting the bytes that arrive, never by waking
  /// up to look.
  Future<bool> output(String needle, {Duration within = const Duration(seconds: 30)}) {
    if (_seen.toString().contains(needle)) return Future.value(true);
    _wanted = needle;
    final completer = _waiting = Completer<bool>();
    return completer.future.timeout(within, onTimeout: () => false);
  }

  void _check() {
    final wanted = _wanted;
    final waiting = _waiting;
    if (wanted == null || waiting == null || waiting.isCompleted) return;
    if (_seen.toString().contains(wanted)) {
      _wanted = null;
      _waiting = null;
      waiting.complete(true);
    }
  }

  Future<void> close() async {
    _socket.destroy();
    await _messages.close();
  }
}

/// The shell this platform runs, and how to make it say a word it was not told.
///
/// Assembled from two variables so the line the shell echoes back does not
/// itself contain the answer: a match proves the child ran it.
List<String> get probeShell => Platform.isWindows ? const ['cmd.exe'] : const ['/bin/sh'];
String get setA => Platform.isWindows ? 'set A=karma' : 'A=karma';
String get setB => Platform.isWindows ? 'set B=shala' : 'B=shala';
String get echoAB => Platform.isWindows ? r'echo %A%%B%' : r'echo $A$B';

/// A directory only this test uses, removed when it can be.
Directory temporaryHome(String prefix) {
  final home = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node or a log can still be held on Windows; the temp
      // directory is the OS's problem after that.
    }
  });
  return home;
}
