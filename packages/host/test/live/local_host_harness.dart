import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The host these tests drive, built once per test isolate.
///
/// **Not `dart run`**, since 2026-09-15: the host depends on `sqlite3`, so every
/// spawn would stage the bundled library into `.dart_tool/`, and eight test
/// workers doing that at once fail with *"Cannot delete file … sqlite3.dll"* —
/// the DLL is held open by the sibling already running. Building once also
/// means these tests exercise the artifact that actually ships.
///
/// **Not one shared output directory either**, and not behind a lock: Dart has
/// no atomic directory claim to serialise the workers with. `createSync()`
/// succeeds silently when the directory already exists — measured 2026-09-15,
/// with and without `recursive` — so every worker "wins" and they delete each
/// other's lock. A directory of its own costs one build for each of the three
/// suites that need a host, and races with nothing.
final Future<String> _host = _buildHost();

/// The built `karmashala_host`, for a test that runs a command other than `serve`.
Future<String> get builtHost => _host;

Future<String> _buildHost() async {
  // Unique per isolate, not per process: isolates sharing a process share a
  // pid and would land on the same directory (see `WslHarness.runSync`).
  final root =
      'build/livehost-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
  final result = await Process.run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '-t',
    'bin/karmashala_host.dart',
    // `-o` rather than the default, so no test knows the `<os>_<arch>` name.
    '-o',
    root,
  ]);
  if (result.exitCode != 0) {
    throw StateError('host build failed: ${result.stdout}${result.stderr}');
  }
  // Absolute, always. `CreateProcess` will not resolve a bare relative path
  // written with forward slashes — `build/…/karmashala_host.exe` comes back as
  // "the system cannot find the file specified" even when the file is sitting
  // right there — so the whole `live` tag failed on Windows while passing on
  // posix, where the same string spawns fine. Measured 2026-09-20.
  final built =
      '$root/bundle/bin/karmashala_host${Platform.isWindows ? '.exe' : ''}';
  return File(built).absolute.path;
}

/// A real `karmashala_host serve` in a home of its own, so a test never touches
/// a host a person is using. Started rather than slept for: [start] waits on the
/// line the daemon prints, and quotes it if the daemon exits instead.
class LocalHost {
  LocalHost._(this.process, this.paths, this.greeting, {this.detached = false});

  /// Started the way the app starts it — detached, in a session with no
  /// terminal — rather than as this test's child.
  final bool detached;

  final Process process;
  final HostPaths paths;

  /// Everything the daemon printed before it was ready.
  final String greeting;

  String get socketPath => paths.socketPath;

  static Future<LocalHost> start(
    Directory home, {
    bool detached = false,
  }) async {
    final process = await Process.start(
      await _host,
      // Port 0: several test hosts run at once and the real default is a fixed
      // port, so they would fight over it and each blame the other.
      ['serve', '--companion-port=0'],
      environment: {'USERPROFILE': home.path, 'HOME': home.path},
      workingDirectory: Directory.current.path,
      mode: detached
          ? ProcessStartMode.detachedWithStdio
          : ProcessStartMode.normal,
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
    // A detached process has no exit code to wait on.
    if (!detached) {
      unawaited(
        process.exitCode.then((code) {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('serve exited $code saying:\n$said'),
            );
          }
        }),
      );
    }
    final greeting = await ready.future.timeout(const Duration(seconds: 90));
    return LocalHost._(
      process,
      HostPaths(Directory('${home.path}/.karmashala')),
      greeting,
      detached: detached,
    );
  }

  /// Kills the daemon with no chance to write anything, so every session it
  /// held is left recorded as running.
  Future<void> kill() async {
    process.kill(ProcessSignal.sigkill);
    if (detached) return;
    await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () => -1,
    );
  }
}

/// The protocol over a plain socket, with no `attach` process in between; the
/// frames are the ones the SSH path sends.
class LocalHostClient {
  LocalHostClient._(this._socket, this.clientId);

  final Socket _socket;
  final String clientId;
  final _parser = FrameParser();
  final _messages = StreamController<HostMessage>.broadcast();

  /// Answers that arrived before anybody asked: `attached` and `exited` come
  /// back to back for an ended session, and a broadcast stream drops those.
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
  void type(int sessionRef, String line) => send(
    InputMessage(sessionRef, Uint8List.fromList(utf8.encode('$line\r\n'))),
  );

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
    final message = await _messages.stream
        .where((m) => m is T)
        .first
        .timeout(within);
    _pending.remove(message);
    return message as T;
  }

  String tail(int n) {
    final s = _seen.toString();
    return s.length <= n ? s : s.substring(s.length - n);
  }

  String? _wanted;
  Completer<bool>? _waiting;

  /// Waits for a substring by counting bytes, never by waking up to look.
  Future<bool> output(
    String needle, {
    Duration within = const Duration(seconds: 30),
  }) {
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

/// The shell this platform runs, asked in two variables so the line it echoes
/// back does not itself contain the answer.
List<String> get probeShell =>
    Platform.isWindows ? const ['cmd.exe'] : const ['/bin/sh'];
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
      // A socket node or a log can still be held on Windows.
    }
  });
  return home;
}
