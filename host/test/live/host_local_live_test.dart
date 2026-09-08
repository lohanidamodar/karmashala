@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The whole host on *this* machine: a real `serve`, a real unix domain socket
/// on Windows, a real ConPTY behind it, and a client that connects to the
/// socket directly rather than through `attach`.
///
/// This is the local stage's own proof, and the answer to "what listener".
/// Nothing here is a named pipe or a loopback port: `HostPaths.socketPath`
/// records why, and this test is what makes that claim checkable on the machine
/// it is claimed about.
///
/// Everything counts — bytes, offsets, frames. Every `Duration` is a failure
/// bound on a future, not a poll.
void main() {
  late Directory home;
  late Process serving;
  late String socketPath;

  setUpAll(() async {
    home = Directory.systemTemp.createTempSync('karmashala-host-local');
    // Its own USERPROFILE (and HOME, for the POSIX spelling), so the test never
    // touches a host a person is using.
    serving = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/karmashala_host.dart', 'serve'],
      environment: {'USERPROFILE': home.path, 'HOME': home.path},
      workingDirectory: Directory.current.path,
    );

    // Started, not slept for: the daemon says where it bound and the test waits
    // on that line. If it exits first, the failure quotes what it said.
    final banner = Completer<String>();
    final said = StringBuffer();
    serving.stdout.transform(utf8.decoder).listen((text) {
      said.write(text);
      if (text.contains('serving on') && !banner.isCompleted) banner.complete(said.toString());
    });
    serving.stderr.transform(utf8.decoder).listen(said.write);
    unawaited(
      serving.exitCode.then((code) {
        if (!banner.isCompleted) {
          banner.completeError(StateError('serve exited $code saying:\n$said'));
        }
      }),
    );
    final greeting = await banner.future.timeout(const Duration(seconds: 90));
    socketPath = HostPaths(Directory('${home.path}/.karmashala')).socketPath;
    expect(greeting, contains(socketPath));
    expect(
      greeting,
      contains(Platform.isWindows ? 'kernel32.dll' : 'libc'),
      reason: 'the host reports which pty layer it measured, never which it assumed',
    );
  });

  tearDownAll(() async {
    serving.kill();
    await serving.exitCode.timeout(const Duration(seconds: 20), onTimeout: () => -1);
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // The socket node or the log can still be held; the temp dir is the OS's
      // problem after that.
    }
  });

  test('a client reaches the socket, runs a shell, and reads its exit code', () async {
    final client = await _SocketClient.connect(socketPath, 'pane-1');
    addTearDown(client.close);

    final welcome = await client.expect<WelcomeMessage>();
    expect(welcome.protocolVersion, kProtocolVersion);
    expect(welcome.hostVersion, kHostVersion);
    expect(welcome.operatingSystem, Platform.operatingSystem);

    client.send(
      OpenMessage(
        requestId: client.nextId(),
        sessionId: 'local-a',
        argv: Platform.isWindows ? const ['cmd.exe'] : const ['/bin/sh'],
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
    );
    final attached = await client.expect<AttachedMessage>();
    expect(attached.sessionId, 'local-a');
    expect(attached.holdsWriteToken, isTrue);
    expect(attached.replayFromOffset, 0);

    // Assembled from two variables so the line the shell echoes back does not
    // itself contain the answer: a match proves the child ran it and the bytes
    // crossed the socket.
    client.send(InputMessage(attached.sessionRef, _type(Platform.isWindows ? _setA : 'A=karma')));
    client.send(InputMessage(attached.sessionRef, _type(Platform.isWindows ? _setB : 'B=shala')));
    client.send(InputMessage(attached.sessionRef, _type(_echoAB)));
    expect(await client.output('karmashala'), isTrue, reason: client.tail(400));

    client.send(InputMessage(attached.sessionRef, _type('exit 7')));
    final exited = await client.expect<ExitedMessage>();
    // The exit code the host reports is the child's, and a code it could not
    // collect stays null rather than becoming a zero.
    expect(exited.exitCode, 7);
    expect(exited.sessionId, 'local-a');
  });

  test('a second client sees the session listed and is refused the write token', () async {
    final owner = await _SocketClient.connect(socketPath, 'pane-owner');
    addTearDown(owner.close);
    await owner.expect<WelcomeMessage>();
    owner.send(
      OpenMessage(
        requestId: owner.nextId(),
        sessionId: 'local-b',
        argv: Platform.isWindows ? const ['cmd.exe'] : const ['/bin/sh'],
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    final held = await owner.expect<AttachedMessage>();
    expect(held.holdsWriteToken, isTrue);

    final observer = await _SocketClient.connect(socketPath, 'pane-observer');
    addTearDown(observer.close);
    await observer.expect<WelcomeMessage>();
    observer.send(ListMessage(observer.nextId()));
    final listed = await observer.expect<SessionsMessage>();
    expect(listed.summaries.map((s) => s.id), contains('local-b'));

    observer.send(
      AttachMessage(
        requestId: observer.nextId(),
        sessionId: 'local-b',
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
    final second = await observer.expect<AttachedMessage>();
    expect(second.holdsWriteToken, isFalse, reason: 'single writer, many readers');
    expect(second.writeHolder, 'pane-owner');

    owner.send(CloseMessage(owner.nextId(), 'local-b'));
    await owner.expect<ClosedMessage>();
  });
}

const _setA = 'set A=karma';
const _setB = 'set B=shala';
String get _echoAB => Platform.isWindows ? r'echo %A%%B%' : r'echo $A$B';

Uint8List _type(String line) => Uint8List.fromList(utf8.encode('$line\r\n'));

/// The protocol over a plain socket — the local transport, with no `attach`
/// process in between. The frames are the ones the SSH path sends, which is the
/// point of `attach` being a byte proxy.
class _SocketClient {
  _SocketClient._(this._socket, this.clientId);

  final Socket _socket;
  final String clientId;
  final _parser = FrameParser();
  final _messages = StreamController<HostMessage>.broadcast();
  final _seen = StringBuffer();
  var _requestId = 0;

  static Future<_SocketClient> connect(String path, String clientId) async {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final client = _SocketClient._(socket, clientId);
    socket.listen(client._onBytes, onError: (Object _) {}, cancelOnError: true);
    client.send(HelloMessage(requestId: client.nextId(), clientId: clientId));
    return client;
  }

  int nextId() => ++_requestId;

  void send(HostMessage message) => _socket.add(message.toFrame().encode());

  void _onBytes(Uint8List chunk) {
    for (final frame in _parser.add(chunk)) {
      final message = decodeMessage(frame);
      if (message is OutputMessage) {
        _seen.write(utf8.decode(message.bytes, allowMalformed: true));
        _check();
      }
      _messages.add(message);
    }
  }

  Future<T> expect<T extends HostMessage>({
    Duration within = const Duration(seconds: 30),
  }) => _messages.stream.where((m) => m is T).cast<T>().first.timeout(within);

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
