import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:ffi/ffi.dart';

import '../pty/conpty.dart' show terminateProcessTree;
import '../pty/win32.dart';

/// What the guard asks of the operating system; [WindowsAcpProcessSystem]
/// in the server, a fake in tests.
abstract interface class AcpProcessSystem {
  /// Puts [pid] in a job that dies with this server; false when refused.
  bool contain(int pid);

  /// When [pid] started, in the system's own units; null when it is gone.
  int? startedAt(int pid);

  /// Ends [pid] and everything it started.
  void killTree(int pid);
}

/// Ties each ACP agent this server starts on Windows to the server's life:
/// it goes in one kill-on-close job, so a server that crashes or is killed
/// takes its agents along, and its PID and start time are recorded in
/// [registryFile], so the next start can end those a job did not reach.
class AcpProcessGuard {
  AcpProcessGuard({required this.registryFile, AcpProcessSystem? system})
    : _system =
          system ?? (Platform.isWindows ? WindowsAcpProcessSystem() : null);

  final String registryFile;
  final AcpProcessSystem? _system;
  final Map<int, int> _live = {};

  /// [start], with every process it starts guarded.
  Future<ProcessHandle> Function(CommandRequest request) guarding(
    Future<ProcessHandle> Function(CommandRequest request) start,
  ) => (request) async {
    final handle = await start(request);
    adopt(handle);
    return handle;
  };

  void adopt(ProcessHandle handle) {
    final system = _system;
    if (system == null || handle is! IoProcessHandle) return;
    final pid = handle.pid;
    system.contain(pid);
    final started = system.startedAt(pid);
    if (started == null) return;
    _live[pid] = started;
    _save();
    handle.exitCode.then(
      (_) => _forget(pid),
      onError: (Object _) {
        _forget(pid);
      },
    );
  }

  /// Ends every recorded agent still running under its recorded start time
  /// — a PID alone may since be somebody else's — and forgets the record.
  /// Called once at start, before any agent is started.
  List<int> reapStale() {
    final system = _system;
    if (system == null) return const [];
    final reaped = <int>[];
    for (final MapEntry(key: pid, value: started) in _load().entries) {
      if (system.startedAt(pid) != started) continue;
      system.killTree(pid);
      reaped.add(pid);
    }
    _live.clear();
    _save();
    return reaped;
  }

  void _forget(int pid) {
    if (_live.remove(pid) != null) _save();
  }

  Map<int, int> _load() {
    try {
      final decoded = jsonDecode(File(registryFile).readAsStringSync());
      if (decoded is! List) return const {};
      return {
        for (final entry in decoded)
          if (entry case {'pid': final int pid, 'started': final int started})
            pid: started,
      };
    } on Object {
      return const {};
    }
  }

  void _save() {
    try {
      File(registryFile)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode([
            for (final MapEntry(key: pid, value: started) in _live.entries)
              {'pid': pid, 'started': started},
          ]),
        );
    } on Object {
      // Unrecorded: the job still ends it with this server.
    }
  }
}

/// [AcpProcessSystem] over kernel32: one job for the server's whole life,
/// whose handle is never closed — the OS closes it, and ends the agents,
/// when this process ends however it ends.
class WindowsAcpProcessSystem implements AcpProcessSystem {
  Kernel32? _k;
  int? _job;

  Kernel32 get _kernel => _k ??= Kernel32.open();

  @override
  bool contain(int pid) {
    final job = _job ??= _createJob();
    if (job == 0) return false;
    final process = _kernel.openProcess(
      kProcessSetQuota | kProcessTerminate,
      0,
      pid,
    );
    if (process == 0) return false;
    try {
      return _kernel.assignProcessToJobObject(job, process) != 0;
    } finally {
      _kernel.closeHandle(process);
    }
  }

  int _createJob() {
    final k = _kernel;
    final job = k.createJobObjectW(nullptr, nullptr);
    if (job == 0) return 0;
    final limits = calloc<Uint8>(kJobExtendedLimitBytes);
    try {
      (limits + kJobLimitFlagsOffset).cast<Uint32>().value =
          kJobObjectLimitKillOnJobClose;
      if (k.setInformationJobObject(
            job,
            kJobObjectExtendedLimitInformation,
            limits.cast<Void>(),
            kJobExtendedLimitBytes,
          ) ==
          0) {
        k.closeHandle(job);
        return 0;
      }
      return job;
    } finally {
      calloc.free(limits);
    }
  }

  @override
  int? startedAt(int pid) {
    final k = _kernel;
    final process = k.openProcess(kProcessQueryLimitedInformation, 0, pid);
    if (process == 0) return null;
    final times = calloc<Uint64>(4);
    try {
      if (k.getProcessTimes(process, times, times + 1, times + 2, times + 3) ==
          0) {
        return null;
      }
      // A process that has exited keeps its handle answerable; it is gone.
      final code = calloc<Uint32>();
      try {
        if (k.getExitCodeProcess(process, code) != 0 &&
            code.value != _stillActive) {
          return null;
        }
      } finally {
        calloc.free(code);
      }
      return times.value;
    } finally {
      calloc.free(times);
      k.closeHandle(process);
    }
  }

  @override
  void killTree(int pid) => terminateProcessTree(_kernel, pid);

  static const int _stillActive = 259;
}
