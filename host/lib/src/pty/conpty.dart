import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pty.dart';
import 'win32.dart';

/// The Windows pty: a ConPTY pseudoconsole, and a child attached to it.
///
/// The shape is the POSIX launcher's, call for call, which is why this is an
/// implementation of [PtyLauncher] rather than a second design: a pair of pipes
/// stands in for the master/slave pair, `CreatePseudoConsole` for `openpty`,
/// `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` for
/// `posix_spawn` with `POSIX_SPAWN_SETSID`, and `ResizePseudoConsole` for
/// `ioctl(TIOCSWINSZ)`. Output is a blocking `ReadFile` in its own isolate and
/// the exit code is the `WaitForSingleObject` that follows it reaching
/// end-of-file, so nothing here polls either.
///
/// Two things genuinely differ, and both are the operating system rather than
/// this class:
///
///  * **A signal number means nothing.** [PtyHandle.kill] terminates instead,
///    so an ended session reports the code `TerminateProcess` set and never
///    `128 + signal`.
///  * **The environment is layered, not replaced.** A Windows child handed an
///    environment block without `SystemRoot` cannot load a DLL, so
///    [PtySpawnRequest.environment] is applied *over* this process's own — the
///    same meaning the app's own `PtyLaunch.environment` already carries.
class ConPtyLauncher implements PtyLauncher {
  ConPtyLauncher({Kernel32? kernel32}) : _k = kernel32 ?? Kernel32.open();

  final Kernel32 _k;

  /// Which library carried the pty entry points on this machine — measured
  /// there, not assumed here. The counterpart of `PosixPtyLauncher.ptyLibrary`.
  String get ptyLibrary => _k.ptyLibrary;

  bool get providesPseudoConsole => _k.providesPseudoConsole;

  @override
  PtyHandle start(PtySpawnRequest request) {
    if (!Platform.isWindows) {
      throw const PtyException('a ConPTY needs a Windows host; this build is not one');
    }
    final create = _k.createPseudoConsole;
    final closePc = _k.closePseudoConsole;
    if (create == null || closePc == null) {
      throw const PtyException(
        'this Windows has no ConPTY (CreatePseudoConsole arrived in 10 1809); '
        'a session cannot be hosted here',
      );
    }
    if (request.argv.isEmpty) {
      throw const PtyException('a session needs an executable to start');
    }

    final arena = Arena();
    var inRead = 0, inWrite = 0, outRead = 0, outWrite = 0, hPc = 0;
    var attributes = nullptr as Pointer<Void>;
    var attributesInitialised = false;
    try {
      final a = arena<IntPtr>(), b = arena<IntPtr>();
      if (_k.createPipe(a, b, nullptr, 0) == 0) {
        throw PtyException('CreatePipe (input) failed', errno: _k.getLastError());
      }
      inRead = a.value;
      inWrite = b.value;
      if (_k.createPipe(a, b, nullptr, 0) == 0) {
        throw PtyException('CreatePipe (output) failed', errno: _k.getLastError());
      }
      outRead = a.value;
      outWrite = b.value;

      final size = arena<Coord>()
        ..ref.X = request.columns
        ..ref.Y = request.rows;
      final pc = arena<IntPtr>();
      final hr = create(size.ref, inRead, outWrite, 0, pc);
      if (hr != 0) {
        throw PtyException('CreatePseudoConsole failed', errno: hr);
      }
      hPc = pc.value;

      // The pseudoconsole owns its ends now. Holding them would keep the pipes
      // alive after the child exits, and the reader would never see EOF — the
      // Windows spelling of the parent dropping the pty slave.
      _k.closeHandle(inRead);
      inRead = 0;
      _k.closeHandle(outWrite);
      outWrite = 0;

      final needed = arena<IntPtr>();
      _k.initializeProcThreadAttributeList(nullptr, 1, 0, needed);
      if (needed.value <= 0) {
        throw PtyException(
          'InitializeProcThreadAttributeList would not size itself',
          errno: _k.getLastError(),
        );
      }
      attributes = calloc<Uint8>(needed.value).cast<Void>();
      if (_k.initializeProcThreadAttributeList(attributes, 1, 0, needed) == 0) {
        throw PtyException('InitializeProcThreadAttributeList failed', errno: _k.getLastError());
      }
      attributesInitialised = true;
      if (_k.updateProcThreadAttribute(
            attributes,
            0,
            kProcThreadAttributePseudoConsole,
            // The HPCON *itself*, not a pointer to it. Every other attribute
            // takes an address and this one does not, which is why the SDK's
            // own sample reads like a type error. Measured 2026-09-09: passing
            // `&hPC` is accepted — `UpdateProcThreadAttribute` and
            // `CreateProcess` both return success — and the child then starts
            // attached to *this* process's console, so the pipe stays empty
            // forever and the reader blocks in `ReadFile` with nothing wrong
            // to report.
            Pointer<Void>.fromAddress(hPc),
            sizeOf<IntPtr>(),
            nullptr,
            nullptr,
          ) ==
          0) {
        throw PtyException('UpdateProcThreadAttribute failed', errno: _k.getLastError());
      }

      final startup = arena<StartupInfoExW>();
      startup.ref
        ..cb = sizeOf<StartupInfoExW>()
        // STARTF_USESTDHANDLES with three nulls, which reads like a mistake and
        // is the opposite of one. Without it the child is handed *this*
        // process's std handles, and `serve` runs with its stdout redirected to
        // a log file: measured 2026-09-09, `cmd.exe /c echo` attached to the
        // pseudoconsole and still wrote its output into that file, so the pane
        // saw nothing. Naming null here refuses the inheritance and leaves the
        // pseudoconsole to supply them, which it does.
        ..dwFlags = kStartfUseStdHandles
        ..hStdInput = 0
        ..hStdOutput = 0
        ..hStdError = 0
        ..lpAttributeList = attributes;

      final info = arena<ProcessInformation>();
      final commandLine = windowsCommandLine(request.argv).toNativeUtf16(allocator: arena);
      final cwd = request.workingDirectory;
      final ok = _k.createProcessW(
        nullptr,
        commandLine,
        nullptr,
        nullptr,
        0,
        kExtendedStartupInfoPresent | kCreateUnicodeEnvironment,
        _environmentBlock(arena, request.environment),
        (cwd == null || cwd.isEmpty) ? nullptr : cwd.toNativeUtf16(allocator: arena),
        startup,
        info,
      );
      if (ok == 0) {
        throw PtyException(
          'CreateProcess(${request.argv.first}) failed',
          errno: _k.getLastError(),
        );
      }
      // Required by CreateProcess, and immediately: nothing here ever resumes
      // or waits on the primary thread.
      _k.closeHandle(info.ref.hThread);

      final handle = _ConPtyHandle(
        kernel32: _k,
        pseudoConsole: hPc,
        inputWrite: inWrite,
        outputRead: outRead,
        processHandle: info.ref.hProcess,
        pid: info.ref.dwProcessId,
      );
      hPc = 0;
      inWrite = 0;
      outRead = 0;
      return handle;
    } finally {
      if (attributes != nullptr) {
        if (attributesInitialised) _k.deleteProcThreadAttributeList(attributes);
        calloc.free(attributes);
      }
      for (final h in [inRead, inWrite, outRead, outWrite]) {
        if (h != 0) _k.closeHandle(h);
      }
      if (hPc != 0) closePc(hPc);
      arena.releaseAll();
    }
  }

  /// `KEY=VALUE\0…\0\0`, UTF-16, over this process's own environment.
  ///
  /// Sorted case-insensitively because `CreateProcess` documents the block that
  /// way, and keyed case-insensitively because Windows variables are: a request
  /// naming `path` must replace `Path` rather than sit beside it.
  Pointer<Void> _environmentBlock(Arena arena, Map<String, String> overrides) {
    final merged = <String, String>{};
    final keys = <String, String>{}; // lower-case name -> the spelling in use
    void put(String key, String value) {
      final existing = keys[key.toLowerCase()];
      if (existing != null) merged.remove(existing);
      keys[key.toLowerCase()] = key;
      merged[key] = value;
    }

    Platform.environment.forEach(put);
    overrides.forEach(put);

    final entries = merged.entries.map((e) => '${e.key}=${e.value}').toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    var units = 1; // the block's own terminator
    for (final entry in entries) {
      units += entry.length + 1;
    }
    final block = arena<Uint16>(units);
    var at = 0;
    for (final entry in entries) {
      for (final unit in entry.codeUnits) {
        block[at++] = unit;
      }
      block[at++] = 0;
    }
    block[at] = 0;
    return block.cast<Void>();
  }
}

class _ConPtyHandle implements PtyHandle {
  _ConPtyHandle({
    required Kernel32 kernel32,
    required int pseudoConsole,
    required int inputWrite,
    required int outputRead,
    required int processHandle,
    required this.pid,
  }) : _k = kernel32,
       _pseudoConsole = pseudoConsole,
       _inputWrite = inputWrite {
    _startReader(outputRead);
    _startExitWatch(processHandle);
  }

  final Kernel32 _k;
  final int _pseudoConsole;
  final int _inputWrite;

  @override
  final int pid;

  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int>();
  Future<SendPort>? _writerReady;
  Isolate? _writer;
  SendPort? _writerPort;
  int? _observedExitCode;
  var _outputDone = false;
  var _pseudoConsoleClosed = false;
  var _closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  /// A pty master reports end-of-file when the last slave fd closes; a
  /// pseudoconsole's pipe does not. conhost stays attached — and the pipe open —
  /// until `ClosePseudoConsole`, so a read loop alone would never learn that the
  /// child had gone. Measured 2026-09-09: `cmd.exe` ran `exit 7`, the process
  /// object signalled, and `ReadFile` sat there.
  ///
  /// So the wait is its own isolate, blocking on the process handle, and the
  /// two meet in [_settle]: the code is not published until the output stream
  /// has ended, which is the ordering the POSIX launcher gets for free from
  /// `waitpid` following EOF.
  Future<void> _startReader(int outputRead) async {
    final port = ReceivePort();
    port.listen((message) {
      if (message is Uint8List) {
        if (!_output.isClosed) _output.add(message);
        return;
      }
      if (message is! List || message.isEmpty) return;
      switch (message.first) {
        case 'done':
          _outputDone = true;
          if (!_output.isClosed) _output.close();
          port.close();
          _settle();
        case 'error':
          if (!_output.isClosed) _output.addError(PtyException(message[1] as String));
      }
    });
    await Isolate.spawn(
      _readerMain,
      [port.sendPort, outputRead],
      debugName: 'conpty-read-$pid',
    );
  }

  Future<void> _startExitWatch(int processHandle) async {
    final port = ReceivePort();
    port.listen((message) {
      _observedExitCode = message as int;
      port.close();
      // The child is gone, so the pseudoconsole has nothing left to serve.
      // Closing it is what ends the read — and what stops a conhost process
      // outliving every session that ever ran.
      _closePseudoConsole();
      _settle();
    });
    await Isolate.spawn(
      _exitWatchMain,
      [port.sendPort, processHandle],
      debugName: 'conpty-wait-$pid',
    );
  }

  void _closePseudoConsole() {
    if (_pseudoConsoleClosed) return;
    _pseudoConsoleClosed = true;
    _k.closePseudoConsole?.call(_pseudoConsole);
  }

  /// The exit code is published once, and only once both halves have answered:
  /// a code delivered before the last bytes would let a pane draw "[exited]"
  /// over output the child had already written.
  void _settle() {
    final code = _observedExitCode;
    if (code == null || !_outputDone || _exit.isCompleted) return;
    _exit.complete(code);
  }

  Future<SendPort> _ensureWriter() =>
      // Memoised on the *future*, not on the result: three writes in one turn
      // would otherwise each spawn their own isolate before the first finished,
      // and the pipe would receive them in whatever order those isolates
      // started. Measured 2026-09-09 against `cmd.exe` — three typed lines
      // arrived third, first, second.
      _writerReady ??= () async {
        final ready = ReceivePort();
        _writer = await Isolate.spawn(
          _writerMain,
          [ready.sendPort, _inputWrite],
          debugName: 'conpty-write-$pid',
        );
        final port = await ready.first as SendPort;
        ready.close();
        return _writerPort = port;
      }();

  @override
  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    // A blocking write on a full pipe must never stall the host, so it happens
    // on its own isolate; ordering is the port's, not a timer's.
    unawaited(_ensureWriter().then((port) => port.send(bytes)).catchError((_) {}));
  }

  @override
  void resize(int columns, int rows) {
    if (_closed || _pseudoConsoleClosed) return;
    final resize = _k.resizePseudoConsole;
    if (resize == null) return;
    final size = calloc<Coord>()
      ..ref.X = columns
      ..ref.Y = rows;
    try {
      resize(_pseudoConsole, size.ref);
    } finally {
      calloc.free(size);
    }
  }

  /// Windows has no signals, so [signal] is ignored here rather than
  /// translated. The tree goes first: a shell's children do not die with it,
  /// and a closed pane that leaves an agent CLI running is the failure this
  /// exists to prevent.
  @override
  void kill([int signal = 15]) {
    if (_closed) return;
    terminateProcessTree(_k, pid);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _writerPort?.send('stop');
    _writer?.kill(priority: Isolate.beforeNextEvent);
    _k.closeHandle(_inputWrite);
    _closePseudoConsole();
    if (!_output.isClosed) await _output.close();
    // A close that raced the exit leaves nothing to wait for; the code stays
    // unknown rather than being invented as a zero.
    if (!_exit.isCompleted) _exit.complete(_observedExitCode ?? -1);
  }
}

/// Terminates [pid] and everything descended from it, children first.
///
/// A parent-pid snapshot rather than a job object because the walk needs no
/// state established at spawn time, so it also works for a process the host
/// adopted rather than started.
void terminateProcessTree(Kernel32 k, int pid) {
  final snapshot = k.createToolhelp32Snapshot(kTh32csSnapProcess, 0);
  if (snapshot == -1 || snapshot == 0) {
    k.terminateProcess(_openForTerminate(k, pid), 1);
    return;
  }
  final entry = calloc<ProcessEntry32W>()..ref.dwSize = sizeOf<ProcessEntry32W>();
  final children = <int, List<int>>{};
  try {
    var more = k.process32FirstW(snapshot, entry);
    while (more != 0) {
      (children[entry.ref.th32ParentProcessID] ??= <int>[]).add(entry.ref.th32ProcessID);
      more = k.process32NextW(snapshot, entry);
    }
  } finally {
    calloc.free(entry);
    k.closeHandle(snapshot);
  }

  // Depth first, and bounded by the snapshot: a pid cannot appear twice in one,
  // so a parent loop cannot make this recurse forever.
  final seen = <int>{};
  void kill(int target) {
    if (!seen.add(target)) return;
    for (final child in children[target] ?? const <int>[]) {
      kill(child);
    }
    final handle = _openForTerminate(k, target);
    if (handle == 0) return;
    k.terminateProcess(handle, 1);
    k.closeHandle(handle);
  }

  for (final child in children[pid] ?? const <int>[]) {
    kill(child);
  }
  final handle = _openForTerminate(k, pid);
  if (handle != 0) {
    k.terminateProcess(handle, 1);
    k.closeHandle(handle);
  }
}

int _openForTerminate(Kernel32 k, int pid) => k.openProcess(kProcessTerminate, 0, pid);

/// Blocking `ReadFile` until the pseudoconsole's write end is gone. This is the
/// reason nothing in the host polls a session for output.
void _readerMain(List<Object> args) {
  final port = args[0] as SendPort;
  final outputRead = args[1] as int;
  final k = Kernel32.open();
  final buffer = calloc<Uint8>(65536);
  final read = calloc<Uint32>();
  try {
    while (true) {
      final ok = k.readFile(outputRead, buffer, 65536, read, nullptr);
      if (ok != 0 && read.value > 0) {
        port.send(Uint8List.fromList(buffer.asTypedList(read.value)));
        continue;
      }
      if (ok != 0) break; // a zero-length read on a pipe is end of file
      final error = k.getLastError();
      // ERROR_BROKEN_PIPE is how a pipe reports "the writer hung up"; anything
      // else is a real fault and is reported as one before we wait.
      if (error != kErrorBrokenPipe) {
        port.send(['error', 'ReadFile(conpty) failed with error $error']);
      }
      break;
    }
  } finally {
    calloc.free(buffer);
    calloc.free(read);
    k.closeHandle(outputRead);
    port.send(const ['done']);
  }
}

/// Blocking `WaitForSingleObject` on the child, in its own isolate. Nothing
/// here polls either: the process object is signalled by the OS.
void _exitWatchMain(List<Object> args) {
  final port = args[0] as SendPort;
  final processHandle = args[1] as int;
  final k = Kernel32.open();
  final code = calloc<Uint32>();
  try {
    var exit = -1;
    if (k.waitForSingleObject(processHandle, kInfinite) == kWaitObject0 &&
        k.getExitCodeProcess(processHandle, code) != 0) {
      exit = code.value;
    }
    port.send(exit);
  } finally {
    calloc.free(code);
    k.closeHandle(processHandle);
  }
}

void _writerMain(List<Object> args) {
  final ready = args[0] as SendPort;
  final inputWrite = args[1] as int;
  final k = Kernel32.open();
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! Uint8List) {
      inbox.close();
      return;
    }
    final buffer = calloc<Uint8>(message.length);
    final written = calloc<Uint32>();
    try {
      buffer.asTypedList(message.length).setAll(0, message);
      var offset = 0;
      while (offset < message.length) {
        final ok = k.writeFile(
          inputWrite,
          buffer + offset,
          message.length - offset,
          written,
          nullptr,
        );
        if (ok == 0 || written.value == 0) break; // the child is gone
        offset += written.value;
      }
    } finally {
      calloc.free(buffer);
      calloc.free(written);
    }
  });
}
