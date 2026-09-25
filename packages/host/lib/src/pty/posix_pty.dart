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
final int _eagain = Platform.isMacOS ? 35 : 11; // EAGAIN

/// The child's environment: the host process's minus [removed], with
/// [overrides] laid over it.
///
/// Layered, not replaced. Until 2026-09-16 this was `overrides` alone, so a
/// pane whose client sent `{'TERM': 'xterm-256color'}` — which is exactly what
/// both the SSH pane and the local-host pane send — started its shell with **no
/// `PATH`, no `HOME` and no `USER`**. The agent itself still ran, because argv[0]
/// is an absolute path resolved on the desktop, but anything it shelled out to
/// had nothing to resolve against and nothing to call a home directory.
///
/// The Windows branch has always layered (`conpty.dart`), for a reason that is
/// only more obviously true here: a block with no `SystemRoot` cannot load a
/// DLL, and a block with no `PATH` cannot find a program. Case-sensitive, unlike
/// that one — POSIX environment names are.
Map<String, String> childEnvironment(
  Map<String, String> overrides, {
  Map<String, String>? base,
  Set<String> removed = const {},
}) => layeredEnvironment(
  base: base ?? Platform.environment,
  overrides: overrides,
  removed: removed,
  caseInsensitive: false,
);

/// [program] as `execvp` would run it: a name with a `/` as given, a bare
/// name found on the `PATH` of [environment] — the child's, not the host's.
/// Throws [PtyException] naming what was searched when nothing there is an
/// executable file, rather than leaving the child to fail as exit 127.
///
/// Every hosted launch comes through here: a pane's program (the app sends an
/// absolute path), an automation's agent (its installation's absolute path)
/// and a project check, whose command is whatever the project wrote — `test`,
/// `flutter`, `npm`.
String resolveExecutable(
  String program,
  Map<String, String> environment, {
  bool Function(String path)? isExecutable,
}) {
  if (program.isEmpty) {
    throw const PtyException('nothing to run: the command is empty');
  }
  if (program.contains('/')) return program;
  final executable = isExecutable ?? _isExecutableFile;
  final path = environment['PATH'] ?? '';
  for (final directory in path.split(':')) {
    // An empty entry is the working directory, as execvp reads it; a relative
    // one would depend on it too, and neither is a place to look for a tool.
    if (directory.isEmpty || !directory.startsWith('/')) continue;
    final candidate = directory.endsWith('/')
        ? '$directory$program'
        : '$directory/$program';
    if (executable(candidate)) return candidate;
  }
  throw PtyException(
    path.isEmpty
        ? '"$program" was not found: the session has no PATH to search'
        : '"$program" was not found on PATH ($path)',
  );
}

bool _isExecutableFile(String path) {
  final stat = FileStat.statSync(path);
  // Any execute bit: whether it is ours is the kernel's question, and the
  // spawn that follows answers it with a real errno.
  return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
}

/// A pty pair from `openpty`, a child from `posix_spawn`, never `forkpty`: its
/// child returns into Dart after a fork in a multithreaded VM, where a malloc
/// lock held by another thread hangs it forever, intermittently.
class PosixPtyLauncher implements PtyLauncher {
  PosixPtyLauncher({Libc? libc, String? ptyExecShim})
    : _libc = libc ?? Libc.open(),
      _shim = ptyExecShim ?? defaultPtyExecShim();

  final Libc _libc;

  /// The host binary, run as `pty-exec` in front of every child on macOS so
  /// the child gets its controlling terminal (see `runPtyExec`). Null where
  /// the terminal is taken on open, or when this is not the host binary.
  final String? _shim;

  /// This executable when it is the host on macOS; null anywhere else,
  /// including a test run under `dart`, which cannot be the shim.
  static String? defaultPtyExecShim() {
    if (!Platform.isMacOS) return null;
    final self = Platform.resolvedExecutable;
    final name = self.split('/').last;
    return name.startsWith('karmashala_host') ? self : null;
  }

  /// Which library carried `openpty`, for the host's own `hello`.
  String get ptyLibrary => _libc.ptySymbolLibrary;
  bool get honoursWorkingDirectory => _libc.faAddChdir != null;

  /// Resolvable on this machine, and never called — see the class comment.
  bool get providesForkpty => _libc.providesForkpty;

  @override
  PtyHandle start(PtySpawnRequest request) {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const PtyException(
        'a pty needs a POSIX host; this build is not one',
      );
    }
    final arena = Arena();
    var masterFd = -1;
    var slaveFd = -1;
    try {
      final master = arena<Int32>();
      final slave = arena<Int32>();
      final name = arena<Uint8>(
        128,
      ); // PATH_MAX is overkill; /dev/pts/N is short.
      final win = arena<Winsize>()
        ..ref.ws_col = request.columns
        ..ref.ws_row = request.rows;

      if (_libc.openpty(master, slave, name, nullptr, win) != 0) {
        throw PtyException('openpty failed', errno: _libc.errno);
      }
      masterFd = master.value;
      slaveFd = slave.value;
      // Close-on-exec at once. `openpty` makes neither end so, and every child
      // spawned afterwards — another session, a check, a `git` from the
      // process worker isolate, and everything *those* start — carried every
      // session's master, and any child spawned before this slave is closed
      // below carried the slave too. A kept master keeps a pty alive after the
      // host lets it go; a kept slave keeps its reader from end-of-file.
      if (!_libc.setCloseOnExec(masterFd) || !_libc.setCloseOnExec(slaveFd)) {
        throw PtyException('fcntl(FD_CLOEXEC) failed', errno: _libc.errno);
      }
      // Non-blocking, so no thread ever sleeps in `read` or `write` on it: the
      // reader and writer wait in `poll` with a timeout instead, and an isolate
      // that returns to its loop can be stopped. One blocked in `read` could
      // not, and kept a host whose main isolate had died from exiting — for
      // ever, holding its sockets (2026-09-25).
      if (!_libc.setNonBlocking(masterFd)) {
        throw PtyException('fcntl(O_NONBLOCK) failed', errno: _libc.errno);
      }

      final pid = _spawn(arena, request, name, masterFd, slaveFd);

      // The parent must drop the slave, or the master never reports end-of-file.
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
      _check(
        _libc.attrSetFlags(
          attr,
          // On macOS the child also starts with nothing but the three fds the
          // file actions below give it, whatever else this process holds —
          // including descriptors `dart:io` or a library opened without
          // close-on-exec, or before it was set.
          kPosixSpawnSetsid |
              (Platform.isMacOS ? kPosixSpawnCloexecDefault : 0),
        ),
        'posix_spawnattr_setflags',
      );
      // Order matters: inherited fds first, then the slave onto 0, then 1 and 2.
      _check(_libc.faAddClose(actions, masterFd), 'addclose(master)');
      _check(_libc.faAddClose(actions, slaveFd), 'addclose(slave)');
      _check(
        _libc.faAddOpen(actions, 0, slaveName, kOReadWrite, 0),
        'addopen(slave)',
      );
      _check(_libc.faAddDup2(actions, 0, 1), 'adddup2(1)');
      _check(_libc.faAddDup2(actions, 0, 2), 'adddup2(2)');

      final cwd = request.workingDirectory;
      final addChdir = _libc.faAddChdir;
      if (cwd != null && cwd.isNotEmpty) {
        if (addChdir == null) {
          throw const PtyException(
            'this libc has no posix_spawn_file_actions_addchdir_np '
            '(glibc < 2.29, macOS < 10.15); '
            'a working directory cannot be honoured',
          );
        }
        _check(addChdir(actions, cString(arena, cwd)), 'addchdir($cwd)');
      }

      final environment = childEnvironment(
        request.environment,
        removed: request.removedEnvironment,
      );
      final shim = _shim;
      final command = [
        if (shim != null) ...[shim, 'pty-exec', '--'],
        // Found here, on the child's own PATH: neither `posix_spawn` nor the
        // shim's `execv` searches, so a bare `test` ran as nothing, exit 127.
        resolveExecutable(request.argv.first, environment),
        ...request.argv.skip(1),
      ];
      final argv = arena<Pointer<Uint8>>(command.length + 1);
      for (var i = 0; i < command.length; i++) {
        argv[i] = cString(arena, command[i]);
      }
      argv[command.length] = nullptr;

      final entries = environment.entries.toList();
      final envp = arena<Pointer<Uint8>>(entries.length + 1);
      for (var i = 0; i < entries.length; i++) {
        envp[i] = cString(arena, '${entries[i].key}=${entries[i].value}');
      }
      envp[entries.length] = nullptr;

      final pidOut = arena<Int32>();
      // posix_spawn returns the error rather than setting errno, and resolves
      // argv[0] on PATH only as posix_spawnp; the path is taken as given.
      final rc = _libc.posixSpawn(
        pidOut,
        cString(arena, command.first),
        actions,
        attr,
        argv,
        envp,
      );
      if (rc != 0) {
        throw PtyException(
          'posix_spawn(${request.argv.first}) failed',
          errno: rc,
        );
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
  _PosixPtyHandle(this._libc, this._masterFd, this.pid)
    : _readerStop = calloc<Int32>() {
    _readerStop.value = 0;
    unawaited(_startReader().catchError(_readerLost));
  }

  /// A reader isolate that could not start ends this session, with the reason,
  /// rather than the host: an unread pty is one session lost, not every one.
  void _readerLost(Object error) {
    if (!_output.isClosed) {
      _output.addError(PtyException('the pty reader could not start: $error'));
    }
    _readerFinished(closedMaster: false);
    if (!_exit.isCompleted) _exit.complete(-1);
    if (!_output.isClosed) _output.close();
  }

  final Libc _libc;
  final int _masterFd;
  @override
  final int pid;

  /// Set to ask the reader to stop; it closes the master itself on the way
  /// out, so the master is never closed under a thread still using it. Freed
  /// once the reader has said its last word.
  final Pointer<Int32> _readerStop;
  var _readerDone = false;

  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int>();
  Future<SendPort>? _writerReady;
  SendPort? _writerPort;
  Pointer<Int32>? _writerStop;
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
      } else if (message is List &&
          message.isNotEmpty &&
          message.first == 'exit') {
        _readerFinished(closedMaster: message[2] as bool);
        if (!_exit.isCompleted) _exit.complete(message[1] as int);
        if (!_output.isClosed) _output.close();
        port.close();
      } else if (message is List && message.first == 'error') {
        if (!_output.isClosed) {
          _output.addError(PtyException(message[1] as String));
        }
      }
    });
    await Isolate.spawn(_readerMain, [
      port.sendPort,
      _masterFd,
      pid,
      _readerStop.address,
    ], debugName: 'pty-read-$pid');
  }

  /// The reader is gone and touches neither the master nor its stop flag
  /// again. A close that came first left the master to it; one it finished
  /// without seeing is completed here.
  void _readerFinished({required bool closedMaster}) {
    if (_readerDone) return;
    _readerDone = true;
    calloc.free(_readerStop);
    if (_closed && !closedMaster) _libc.close(_masterFd);
  }

  Future<SendPort> _ensureWriter() =>
      // Memoised on the *future*: three writes in one turn would otherwise each
      // spawn an isolate and reach the pty in whatever order those started.
      _writerReady ??= () async {
        // A descriptor of its own, which it closes itself: the master can then
        // be closed here without a write landing on a number the kernel has
        // since handed to something else.
        final fd = _libc.fcntl(_masterFd, kFDupFdCloexec, 0);
        if (fd < 0) {
          throw PtyException('dup(pty) failed', errno: _libc.errno);
        }
        final stop = calloc<Int32>()..value = 0;
        final ready = ReceivePort();
        try {
          await Isolate.spawn(_writerMain, [
            ready.sendPort,
            fd,
            stop.address,
          ], debugName: 'pty-write-$pid');
        } on Object {
          ready.close();
          _libc.close(fd);
          calloc.free(stop);
          rethrow;
        }
        final port = await ready.first as SendPort;
        ready.close();
        _writerStop = stop;
        _writerPort = port;
        // Closed while it started: it is told at once, as close() would have.
        if (_closed) _stopWriter();
        return port;
      }();

  /// The writer frees its flag and closes its descriptor when this arrives;
  /// nothing here touches either afterwards.
  void _stopWriter() {
    final port = _writerPort;
    final stop = _writerStop;
    if (port == null || stop == null) return;
    _writerPort = null;
    _writerStop = null;
    stop.value = 1;
    port.send('stop');
  }

  @override
  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    // A write on a full pty buffer waits in the writer isolate, never here.
    unawaited(
      _ensureWriter()
          .then((port) {
            if (!_closed) port.send(bytes);
          })
          .catchError((_) {}),
    );
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

  /// The whole session, not the leader: spawned with setsid, the child leads a
  /// group of its own pid, and a shell moves each job into a group of its own.
  @override
  void kill([int signal = 15]) {
    if (_closed) return;
    _libc.kill(-pid, signal);
    // A job the shell moved into a group of its own — `claude login` typed at
    // a zsh prompt — is still in the session, and holding the slave it keeps
    // the reader from its end-of-file, so the session could never end.
    final members = Platform.isMacOS
        ? _libc.sessionMembersByListing(pid)
        : sessionMembers(pid);
    for (final member in members) {
      _libc.kill(member, signal);
    }
  }

  /// Lets go of the pty. Once the reader is done this closes the master
  /// directly; while it still runs — a child that escaped the session still
  /// holds the slave — the reader is asked to stop and closes it itself, within
  /// one poll interval. Never a close under a thread still using the master:
  /// on macOS that could sleep in the kernel for good, and on this isolate it
  /// stopped the host answering anyone (2026-09-24).
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopWriter();
    if (_readerDone) {
      _libc.close(_masterFd);
    } else {
      _readerStop.value = 1;
    }
    if (!_output.isClosed) await _output.close();
  }
}

/// Every process whose session id is [sid], read from `/proc`; empty where
/// there is none (macOS), which leaves the process group as the reach.
List<int> sessionMembers(int sid, {Directory? proc}) {
  final root = proc ?? Directory('/proc');
  if (!root.existsSync()) return const [];
  final members = <int>[];
  for (final entry in root.listSync(followLinks: false)) {
    final pid = int.tryParse(
      entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    if (pid == null || pid == sid) continue;
    try {
      final stat = File('${entry.path}/stat').readAsStringSync();
      if (sessionIdOf(stat) == sid) members.add(pid);
    } on FileSystemException {
      // Gone between the listing and the read.
    }
  }
  return members;
}

/// Field 6 of `/proc/<pid>/stat`, counted from after the `(comm)`, which may
/// itself hold spaces and parentheses.
int? sessionIdOf(String stat) {
  final fields = stat
      .substring(stat.lastIndexOf(')') + 1)
      .trim()
      .split(RegExp(r'\s+'));
  return fields.length > 3 ? int.tryParse(fields[3]) : null;
}

/// How long the reader and writer wait in `poll` before looking at their stop
/// flag again. Also how soon an isolate of theirs can be ended: a Dart loop is
/// interruptible between calls, never inside one.
const int _pollMillis = 200;

/// How long a reader asked to stop still waits for its child's exit code.
const Duration _reapAfterStop = Duration(seconds: 2);

/// `poll` then `read` until the child's side is gone or [_readerStop] is set,
/// then `waitpid` without blocking. Nothing here sleeps in the kernel for
/// longer than [_pollMillis], so the isolate can always be stopped — by its
/// flag, or by the VM shutting down.
void _readerMain(List<Object> args) {
  final port = args[0] as SendPort;
  final fd = args[1] as int;
  final pid = args[2] as int;
  final stop = Pointer<Int32>.fromAddress(args[3] as int);
  final libc = Libc.open();
  final buffer = calloc<Uint8>(65536);
  final poll = calloc<PollFd>();
  var stopped = false;
  try {
    while (true) {
      if (stop.value != 0) {
        stopped = true;
        break;
      }
      poll.ref
        ..fd = fd
        ..events = kPollIn
        ..revents = 0;
      final ready = libc.poll(poll, 1, _pollMillis);
      if (ready == 0) continue;
      if (ready < 0) {
        final err = libc.errno;
        if (err == _eintr) continue;
        port.send(['error', 'poll(pty) failed with errno $err']);
        break;
      }
      final n = libc.read(fd, buffer, 65536);
      if (n > 0) {
        port.send(Uint8List.fromList(buffer.asTypedList(n)));
        continue;
      }
      if (n == 0) break; // end of file: every slave fd is closed
      final err = libc.errno;
      if (err == _eintr) continue;
      if (err == _eagain) {
        // Readable by `poll` and empty to `read`: a hang-up with no data left.
        if (poll.ref.revents & (kPollHup | kPollErr | kPollNval) != 0) break;
        continue;
      }
      // EIO is the child hanging up (Linux, and macOS once the slave is gone);
      // anything else is a fault.
      if (err != _eio) port.send(['error', 'read(pty) failed with errno $err']);
      break;
    }
  } finally {
    calloc.free(poll);
    calloc.free(buffer);
  }
  // Asked to stop: the master is ours to close, and closing it hangs up
  // whatever still holds the slave.
  if (stopped) libc.close(fd);

  final status = calloc<Int32>();
  try {
    var code = -1;
    Stopwatch? sinceStop = stopped ? (Stopwatch()..start()) : null;
    while (true) {
      final rc = libc.waitpid(pid, status, kWNoHang);
      if (rc == pid) {
        code = _decodeWaitStatus(status.value);
        break;
      }
      if (rc < 0) {
        if (libc.errno == _eintr) continue;
        // ECHILD: reaped already — `dart:io`'s exit handler reaps *every*
        // child while it has a process of its own to wait for — or not ours.
        break;
      }
      // Still running with the slave closed. Waited for until the session is
      // let go, then only briefly: it was killed on the way.
      if (stop.value != 0) sinceStop ??= Stopwatch()..start();
      if (sinceStop != null && sinceStop.elapsed > _reapAfterStop) break;
      libc.poll(nullptr, 0, 50);
    }
    port.send(['exit', code, stopped]);
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

/// Writes what it is sent to its own duplicate of the master, waiting in
/// `poll` — never in `write` — while the child is not reading; `'stop'`
/// closes the duplicate, frees the flag and ends it.
void _writerMain(List<Object> args) {
  final ready = args[0] as SendPort;
  final fd = args[1] as int;
  final stop = Pointer<Int32>.fromAddress(args[2] as int);
  final libc = Libc.open();
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! Uint8List) {
      libc.close(fd);
      calloc.free(stop);
      inbox.close();
      return;
    }
    if (stop.value != 0) return;
    final buffer = calloc<Uint8>(message.length);
    final poll = calloc<PollFd>();
    try {
      buffer.asTypedList(message.length).setAll(0, message);
      var offset = 0;
      while (offset < message.length && stop.value == 0) {
        final n = libc.write(fd, buffer + offset, message.length - offset);
        if (n > 0) {
          offset += n;
          continue;
        }
        final err = libc.errno;
        if (err == _eintr) continue;
        if (err == _eagain) {
          poll.ref
            ..fd = fd
            ..events = kPollOut
            ..revents = 0;
          libc.poll(poll, 1, _pollMillis);
          continue;
        }
        break; // the child is gone; dropping the rest is the only option
      }
    } finally {
      calloc.free(poll);
      calloc.free(buffer);
    }
  });
}
