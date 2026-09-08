import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libc.dart';
import 'pty.dart';

const int _eintr = 4;
const int _eio = 5;
const int _eagain = 11;

/// The real thing: a pty pair from `openpty`, a child from `posix_spawn`.
///
/// `forkpty` is not used even though it is the obvious call. After `fork` in a
/// multithreaded VM only async-signal-safe code may run, and the child of
/// `forkpty` returns into Dart — a malloc lock held by another thread at the
/// moment of the fork would hang it forever, intermittently. `posix_spawn` with
/// POSIX_SPAWN_SETSID reaches the same place: the child is a session leader, and
/// opening the slave device without O_NOCTTY makes it the controlling terminal.
class PosixPtyLauncher implements PtyLauncher {
  PosixPtyLauncher({Libc? libc}) : _libc = libc ?? Libc.open();

  final Libc _libc;

  /// Which library carried `openpty`, for the host's own `hello`.
  String get ptyLibrary => _libc.ptySymbolLibrary;
  bool get honoursWorkingDirectory => _libc.faAddChdir != null;

  @override
  PtyHandle start(PtySpawnRequest request) {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const PtyException('a pty needs a POSIX host; this build is not one');
    }
    final arena = Arena();
    var masterFd = -1;
    var slaveFd = -1;
    try {
      final master = arena<Int32>();
      final slave = arena<Int32>();
      final name = arena<Uint8>(128); // PATH_MAX is overkill; /dev/pts/N is short.
      final win = arena<Winsize>()
        ..ref.ws_col = request.columns
        ..ref.ws_row = request.rows;

      if (_libc.openpty(master, slave, name, nullptr, win) != 0) {
        throw PtyException('openpty failed', errno: _libc.errno);
      }
      masterFd = master.value;
      slaveFd = slave.value;

      final pid = _spawn(arena, request, name, masterFd, slaveFd);

      // The parent must drop the slave, or the master never reports end-of-file
      // when the child exits and the session would look alive forever.
      _libc.close(slaveFd);
      slaveFd = -1;
      final handle = _PosixPtyHandle(_libc, masterFd, pid);
      masterFd = -1;
      return handle;
    } finally {
      if (slaveFd >= 0) _libc.close(slaveFd);
      if (masterFd >= 0) _libc.close(masterFd);
      arena.releaseAll();
    }
  }

  int _spawn(
    Arena arena,
    PtySpawnRequest request,
    Pointer<Uint8> slaveName,
    int masterFd,
    int slaveFd,
  ) {
    final actions = arena<Uint8>(kOpaqueSpawnStructBytes).cast<Void>();
    final attr = arena<Uint8>(kOpaqueSpawnStructBytes).cast<Void>();
    _check(_libc.faInit(actions), 'posix_spawn_file_actions_init');
    _check(_libc.attrInit(attr), 'posix_spawnattr_init');
    try {
      _check(_libc.attrSetFlags(attr, kPosixSpawnSetsid), 'posix_spawnattr_setflags');
      // Order matters: the inherited fds go first, then the slave becomes 0,
      // and only then is it duplicated onto 1 and 2.
      _check(_libc.faAddClose(actions, masterFd), 'addclose(master)');
      _check(_libc.faAddClose(actions, slaveFd), 'addclose(slave)');
      _check(_libc.faAddOpen(actions, 0, slaveName, kOReadWrite, 0), 'addopen(slave)');
      _check(_libc.faAddDup2(actions, 0, 1), 'adddup2(1)');
      _check(_libc.faAddDup2(actions, 0, 2), 'adddup2(2)');

      final cwd = request.workingDirectory;
      final addChdir = _libc.faAddChdir;
      if (cwd != null && cwd.isNotEmpty) {
        if (addChdir == null) {
          throw const PtyException(
            'this libc has no posix_spawn_file_actions_addchdir_np (glibc < 2.29); '
            'a working directory cannot be honoured',
          );
        }
        _check(addChdir(actions, cString(arena, cwd)), 'addchdir($cwd)');
      }

      final argv = arena<Pointer<Uint8>>(request.argv.length + 1);
      for (var i = 0; i < request.argv.length; i++) {
        argv[i] = cString(arena, request.argv[i]);
      }
      argv[request.argv.length] = nullptr;

      final entries = request.environment.entries.toList();
      final envp = arena<Pointer<Uint8>>(entries.length + 1);
      for (var i = 0; i < entries.length; i++) {
        envp[i] = cString(arena, '${entries[i].key}=${entries[i].value}');
      }
      envp[entries.length] = nullptr;

      final pidOut = arena<Int32>();
      // posix_spawn returns the error rather than setting errno, and resolves
      // argv[0] on the caller's PATH only through posix_spawnp; we take the
      // path as given so a session records exactly what was started.
      final rc = _libc.posixSpawn(
        pidOut,
        cString(arena, request.argv.first),
        actions,
        attr,
        argv,
        envp,
      );
      if (rc != 0) {
        throw PtyException('posix_spawn(${request.argv.first}) failed', errno: rc);
      }
      return pidOut.value;
    } finally {
      _libc.faDestroy(actions);
      _libc.attrDestroy(attr);
    }
  }

  void _check(int rc, String what) {
    if (rc != 0) throw PtyException('$what failed', errno: rc);
  }
}

class _PosixPtyHandle implements PtyHandle {
  _PosixPtyHandle(this._libc, this._masterFd, this.pid) {
    _startReader();
  }

  final Libc _libc;
  final int _masterFd;
  @override
  final int pid;

  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int>();
  SendPort? _writerPort;
  Isolate? _writer;
  var _closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  Future<void> _startReader() async {
    final port = ReceivePort();
    port.listen((message) {
      if (message is Uint8List) {
        if (!_output.isClosed) _output.add(message);
      } else if (message is List && message.isNotEmpty && message.first == 'exit') {
        if (!_exit.isCompleted) _exit.complete(message[1] as int);
        if (!_output.isClosed) _output.close();
        port.close();
      } else if (message is List && message.first == 'error') {
        if (!_output.isClosed) _output.addError(PtyException(message[1] as String));
      }
    });
    await Isolate.spawn(_readerMain, [port.sendPort, _masterFd, pid], debugName: 'pty-read-$pid');
  }

  Future<SendPort> _ensureWriter() async {
    final existing = _writerPort;
    if (existing != null) return existing;
    final ready = ReceivePort();
    _writer = await Isolate.spawn(_writerMain, [
      ready.sendPort,
      _masterFd,
    ], debugName: 'pty-write-$pid');
    final port = await ready.first as SendPort;
    ready.close();
    return _writerPort = port;
  }

  @override
  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    // A blocking write on a full pty buffer must never stall the host, so it
    // happens on its own isolate; ordering is the port's, not a timer's.
    unawaited(_ensureWriter().then((port) => port.send(bytes)).catchError((_) {}));
  }

  @override
  void resize(int columns, int rows) {
    if (_closed) return;
    final win = calloc<Winsize>()
      ..ref.ws_col = columns
      ..ref.ws_row = rows;
    try {
      _libc.ioctlWinsize(_masterFd, kTIOCSWINSZ, win);
    } finally {
      calloc.free(win);
    }
  }

  @override
  void kill([int signal = 15]) {
    if (_closed) return;
    _libc.kill(pid, signal);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _writerPort?.send('stop');
    _writer?.kill(priority: Isolate.beforeNextEvent);
    _libc.close(_masterFd);
    if (!_output.isClosed) await _output.close();
  }
}

/// Blocking `read` until the child's side is gone, then `waitpid`. This is the
/// reason nothing in the host polls a session for liveness.
void _readerMain(List<Object> args) {
  final port = args[0] as SendPort;
  final fd = args[1] as int;
  final pid = args[2] as int;
  final libc = Libc.open();
  final buffer = calloc<Uint8>(65536);
  try {
    while (true) {
      final n = libc.read(fd, buffer, 65536);
      if (n > 0) {
        port.send(Uint8List.fromList(buffer.asTypedList(n)));
        continue;
      }
      if (n == 0) break; // end of file: every slave fd is closed
      final err = libc.errno;
      if (err == _eintr || err == _eagain) continue;
      // EIO on Linux is how a master reports "the child hung up"; anything
      // else is a real fault and is reported as one before we reap.
      if (err != _eio) port.send(['error', 'read(pty) failed with errno $err']);
      break;
    }
  } finally {
    calloc.free(buffer);
  }
  final status = calloc<Int32>();
  try {
    var code = -1;
    while (true) {
      final rc = libc.waitpid(pid, status, 0);
      if (rc == pid) {
        code = _decodeWaitStatus(status.value);
        break;
      }
      if (rc < 0 && libc.errno == _eintr) continue;
      break; // already reaped, or not ours: the code stays unknown
    }
    port.send(['exit', code]);
  } finally {
    calloc.free(status);
  }
}

/// WIFEXITED/WEXITSTATUS and WIFSIGNALED/WTERMSIG, without a header.
/// A signalled child reports `128 + signal`, so callers never decode a status.
int _decodeWaitStatus(int status) {
  final low = status & 0x7f;
  if (low == 0) return (status >> 8) & 0xff;
  if (low == 0x7f) return -1; // stopped, not exited
  return 128 + low;
}

void _writerMain(List<Object> args) {
  final ready = args[0] as SendPort;
  final fd = args[1] as int;
  final libc = Libc.open();
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! Uint8List) {
      inbox.close();
      return;
    }
    final buffer = calloc<Uint8>(message.length);
    try {
      buffer.asTypedList(message.length).setAll(0, message);
      var offset = 0;
      while (offset < message.length) {
        final n = libc.write(fd, buffer + offset, message.length - offset);
        if (n > 0) {
          offset += n;
          continue;
        }
        final err = libc.errno;
        if (err == _eintr || err == _eagain) continue;
        break; // the child is gone; dropping the rest is the only option
      }
    } finally {
      calloc.free(buffer);
    }
  });
}
