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
/// Two things differ from POSIX and both are the OS: [PtyHandle.kill]
/// terminates rather than signalling, so an ended session never reports
/// `128 + signal`; and [PtySpawnRequest.environment] is layered *over* this
/// process's own, because a child with no `SystemRoot` cannot load a DLL.
class ConPtyLauncher implements PtyLauncher {
  ConPtyLauncher({Kernel32? kernel32, void Function(String line)? log})
    : _k = kernel32 ?? Kernel32.open(),
      _log = log ?? stderr.writeln;

  final Kernel32 _k;
  final void Function(String line) _log;

  /// Which library carried the pty entry points here — measured, not assumed.
  String get ptyLibrary => _k.ptyLibrary;

  bool get providesPseudoConsole => _k.providesPseudoConsole;

  @override
  PtyHandle start(PtySpawnRequest request) {
    if (!Platform.isWindows) {
      throw const PtyException(
        'a ConPTY needs a Windows host; this build is not one',
      );
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
    var inRead = 0, inWrite = 0, outRead = 0, outWrite = 0, hPc = 0, job = 0;
    try {
      final a = arena<IntPtr>(), b = arena<IntPtr>();
      if (_k.createPipe(a, b, nullptr, 0) == 0) {
        throw PtyException(
          'CreatePipe (input) failed',
          errno: _k.getLastError(),
        );
      }
      inRead = a.value;
      inWrite = b.value;
      if (_k.createPipe(a, b, nullptr, 0) == 0) {
        throw PtyException(
          'CreatePipe (output) failed',
          errno: _k.getLastError(),
        );
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

      // The pseudoconsole owns these ends now; holding them would keep the
      // pipes alive past the child's exit and the reader would never see EOF.
      _k.closeHandle(inRead);
      inRead = 0;
      _k.closeHandle(outWrite);
      outWrite = 0;

      // Redirection Guard off for the child (BACKLOG §2). A failure with it is
      // tried once more without it, whatever its error: the error is read by
      // a second FFI call, which the VM can clobber (a first pane read 0).
      var created = _createChild(arena, hPc, request, mitigation: true);
      if (created.info == null) {
        _log(
          'karmashala_host: this Windows refused the redirection-trust '
          'mitigation for ${request.argv.first} (error ${created.error}); '
          "started it without, so it inherits the server's policy",
        );
        created = _createChild(arena, hPc, request, mitigation: false);
      }
      final info =
          created.info ??
          (throw PtyException(
            'CreateProcess(${request.argv.first}) failed',
            errno: created.error,
          ));

      // In its job before it runs a single instruction: started suspended,
      // so no grandchild can be spawned outside it and outlive the server.
      job = _adopt(arena, info.hProcess);
      _k.resumeThread(info.hThread);
      // Required by CreateProcess; nothing here waits on the primary thread.
      _k.closeHandle(info.hThread);

      final handle = _ConPtyHandle(
        kernel32: _k,
        pseudoConsole: hPc,
        inputWrite: inWrite,
        outputRead: outRead,
        processHandle: info.hProcess,
        job: job,
        pid: info.dwProcessId,
      );
      hPc = 0;
      inWrite = 0;
      outRead = 0;
      job = 0;
      return handle;
    } finally {
      for (final h in [inRead, inWrite, outRead, outWrite, job]) {
        if (h != 0) _k.closeHandle(h);
      }
      if (hPc != 0) closePc(hPc);
      arena.releaseAll();
    }
  }

  /// Starts the child on [hPc], suspended, with a fresh attribute list: the
  /// pseudoconsole, and the redirection-trust policy when [mitigation]. The
  /// info, or the error `CreateProcess` gave (null info).
  ({ProcessInformation? info, int error}) _createChild(
    Arena arena,
    int hPc,
    PtySpawnRequest request, {
    required bool mitigation,
  }) {
    final count = paneAttributeCount(mitigation: mitigation);
    var attributes = nullptr as Pointer<Void>;
    var initialised = false;
    try {
      final needed = arena<IntPtr>();
      _k.initializeProcThreadAttributeList(nullptr, count, 0, needed);
      if (needed.value <= 0) {
        throw PtyException(
          'InitializeProcThreadAttributeList would not size itself',
          errno: _k.getLastError(),
        );
      }
      attributes = calloc<Uint8>(needed.value).cast<Void>();
      if (_k.initializeProcThreadAttributeList(attributes, count, 0, needed) ==
          0) {
        throw PtyException(
          'InitializeProcThreadAttributeList failed',
          errno: _k.getLastError(),
        );
      }
      initialised = true;
      if (_k.updateProcThreadAttribute(
            attributes,
            0,
            kProcThreadAttributePseudoConsole,
            // The HPCON *itself*, not a pointer to it: passing `&hPC` succeeds
            // and silently attaches the child to this process's own console.
            Pointer<Void>.fromAddress(hPc),
            sizeOf<IntPtr>(),
            nullptr,
            nullptr,
          ) ==
          0) {
        throw PtyException(
          'UpdateProcThreadAttribute failed',
          errno: _k.getLastError(),
        );
      }
      if (mitigation) {
        final words = redirectionTrustOffPolicy();
        // Lives in the arena, past CreateProcess: the list points at it.
        final policy = arena<Uint64>(words.length);
        for (var i = 0; i < words.length; i++) {
          policy[i] = words[i];
        }
        if (_k.updateProcThreadAttribute(
              attributes,
              0,
              kProcThreadAttributeMitigationPolicy,
              policy.cast<Void>(),
              sizeOf<Uint64>() * words.length,
              nullptr,
              nullptr,
            ) ==
            0) {
          // Not the launch: the policy alone was refused, so start without it.
          return (info: null, error: kErrorInvalidParameter);
        }
      }

      final startup = arena<StartupInfoExW>();
      startup.ref
        ..cb = sizeOf<StartupInfoExW>()
        // Three nulls refuse inheritance of this process's std handles, which
        // `serve` has redirected to a log file; the pseudoconsole supplies them.
        ..dwFlags = kStartfUseStdHandles
        ..hStdInput = 0
        ..hStdOutput = 0
        ..hStdError = 0
        ..lpAttributeList = attributes;

      final info = arena<ProcessInformation>();
      final commandLine = windowsCommandLine(
        request.argv,
      ).toNativeUtf16(allocator: arena);
      final cwd = request.workingDirectory;
      final ok = _k.createProcessW(
        nullptr,
        commandLine,
        nullptr,
        nullptr,
        0,
        kExtendedStartupInfoPresent |
            kCreateUnicodeEnvironment |
            kCreateSuspended,
        _environmentBlock(arena, request),
        (cwd == null || cwd.isEmpty)
            ? nullptr
            : cwd.toNativeUtf16(allocator: arena),
        startup,
        info,
      );
      if (ok == 0) return (info: null, error: _k.getLastError());
      return (info: info.ref, error: 0);
    } finally {
      if (attributes != nullptr) {
        if (initialised) _k.deleteProcThreadAttributeList(attributes);
        calloc.free(attributes);
      }
    }
  }

  /// Puts the child in a job that dies with this process; 0 when the OS would
  /// not give us one, which is not fatal.
  ///
  /// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is what makes "their processes died
  /// with the host" true of a host terminated rather than asked to stop.
  int _adopt(Arena arena, int processHandle) {
    final job = _k.createJobObjectW(nullptr, nullptr);
    if (job == 0) return 0;
    final limits = arena<Uint8>(kJobExtendedLimitBytes);
    limits
        .cast<Uint8>()
        .asTypedList(kJobExtendedLimitBytes)
        .fillRange(0, kJobExtendedLimitBytes, 0);
    (limits + kJobLimitFlagsOffset).cast<Uint32>().value =
        kJobObjectLimitKillOnJobClose;
    if (_k.setInformationJobObject(
              job,
              kJobObjectExtendedLimitInformation,
              limits.cast<Void>(),
              kJobExtendedLimitBytes,
            ) ==
            0 ||
        _k.assignProcessToJobObject(job, processHandle) == 0) {
      _k.closeHandle(job);
      return 0;
    }
    return job;
  }

  /// `KEY=VALUE\0…\0\0`, UTF-16, from [conPtyEnvironmentEntries].
  Pointer<Void> _environmentBlock(Arena arena, PtySpawnRequest request) {
    final entries = conPtyEnvironmentEntries(
      base: Platform.environment,
      request: request,
    );
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
    required int job,
    required this.pid,
  }) : _k = kernel32,
       _pseudoConsole = pseudoConsole,
       _inputWrite = inputWrite,
       _job = job {
    unawaited(
      _startReader(
        outputRead,
      ).catchError((Object e) => _watchLost('reader', e)),
    );
    unawaited(
      _startExitWatch(
        processHandle,
      ).catchError((Object e) => _watchLost('exit watch', e)),
    );
  }

  /// An isolate that could not start ends this session, with the reason,
  /// rather than the host: one session lost, not every one.
  void _watchLost(String which, Object error) {
    if (!_output.isClosed) {
      _output.addError(
        PtyException('the conpty $which could not start: $error'),
      );
    }
    _outputDone = true;
    _observedExitCode ??= -1;
    if (!_output.isClosed) _output.close();
    _settle();
  }

  final Kernel32 _k;
  final int _pseudoConsole;
  final int _inputWrite;

  /// Closed last: while it is open the OS kills the child if this process dies.
  final int _job;

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

  /// A pseudoconsole's pipe never reports end-of-file — conhost holds it open
  /// until `ClosePseudoConsole` — so the exit is watched in its own isolate and
  /// the two meet in [_settle].
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
          if (!_output.isClosed) {
            _output.addError(PtyException(message[1] as String));
          }
      }
    });
    await Isolate.spawn(_readerMain, [
      port.sendPort,
      outputRead,
    ], debugName: 'conpty-read-$pid');
  }

  Future<void> _startExitWatch(int processHandle) async {
    final port = ReceivePort();
    port.listen((message) {
      _observedExitCode = message as int;
      port.close();
      // Closing the pseudoconsole is what ends the read, and what stops a
      // conhost outliving every session that ever ran.
      _closePseudoConsole();
      _settle();
    });
    await Isolate.spawn(_exitWatchMain, [
      port.sendPort,
      processHandle,
    ], debugName: 'conpty-wait-$pid');
  }

  void _closePseudoConsole() {
    if (_pseudoConsoleClosed) return;
    _pseudoConsoleClosed = true;
    _k.closePseudoConsole?.call(_pseudoConsole);
  }

  /// Published once, and only once both halves have answered: a code ahead of
  /// the last bytes would draw "[exited]" over output the child had written.
  void _settle() {
    final code = _observedExitCode;
    if (code == null || !_outputDone || _exit.isCompleted) return;
    _exit.complete(code);
  }

  Future<SendPort> _ensureWriter() =>
      // Memoised on the *future*: three writes in one turn would otherwise each
      // spawn an isolate and reach the pipe in whatever order those started.
      _writerReady ??= () async {
        final ready = ReceivePort();
        _writer = await Isolate.spawn(_writerMain, [
          ready.sendPort,
          _inputWrite,
        ], debugName: 'conpty-write-$pid');
        final port = await ready.first as SendPort;
        ready.close();
        return _writerPort = port;
      }();

  @override
  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    // A blocking write on a full pipe must never stall the host.
    unawaited(
      _ensureWriter().then((port) => port.send(bytes)).catchError((_) {}),
    );
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

  /// Windows has no signals, so [signal] is ignored rather than translated. The
  /// tree goes first: a shell's children do not die with it.
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
    if (_job != 0) _k.closeHandle(_job);
    if (!_output.isClosed) await _output.close();
    // A close that raced the exit leaves the code unknown rather than zero.
    if (!_exit.isCompleted) _exit.complete(_observedExitCode ?? -1);
  }
}

/// Terminates [pid] and everything descended from it, children first. Uses a
/// parent-pid snapshot, so it also works for a process the host merely adopted.
void terminateProcessTree(Kernel32 k, int pid) {
  final snapshot = k.createToolhelp32Snapshot(kTh32csSnapProcess, 0);
  if (snapshot == -1 || snapshot == 0) {
    k.terminateProcess(_openForTerminate(k, pid), 1);
    return;
  }
  final entry = calloc<ProcessEntry32W>()
    ..ref.dwSize = sizeOf<ProcessEntry32W>();
  final children = <int, List<int>>{};
  try {
    var more = k.process32FirstW(snapshot, entry);
    while (more != 0) {
      (children[entry.ref.th32ParentProcessID] ??= <int>[]).add(
        entry.ref.th32ProcessID,
      );
      more = k.process32NextW(snapshot, entry);
    }
  } finally {
    calloc.free(entry);
    k.closeHandle(snapshot);
  }

  // Bounded by the snapshot: a pid cannot appear twice, so this cannot loop.
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

int _openForTerminate(Kernel32 k, int pid) =>
    k.openProcess(kProcessTerminate, 0, pid);

/// Blocking `ReadFile` until the pseudoconsole's write end is gone — no poll.
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
      // ERROR_BROKEN_PIPE is the writer hanging up; anything else is a fault.
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

/// Blocking `WaitForSingleObject` on the child, in its own isolate.
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

/// The `KEY=VALUE` lines a ConPTY child is started with: [base] minus the
/// request's removals, its overrides laid over that, case-insensitively and in
/// the case-insensitive order `CreateProcessW` expects.
List<String> conPtyEnvironmentEntries({
  required Map<String, String> base,
  required PtySpawnRequest request,
}) =>
    layeredEnvironment(
        base: base,
        overrides: request.environment,
        removed: request.removedEnvironment,
        caseInsensitive: true,
      ).entries.map((e) => '${e.key}=${e.value}').toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
