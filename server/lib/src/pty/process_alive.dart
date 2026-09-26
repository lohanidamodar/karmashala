import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'libc.dart';
import 'win32.dart';

const int _eperm = 1;
const int _processQueryLimitedInformation = 0x1000;
const int _errorAccessDenied = 5;
const int _stillActive = 259;

/// Whether a process with [pid] exists, asked without signalling it.
///
/// POSIX: `kill(pid, 0)`, which checks and delivers nothing — `EPERM` is a
/// process that is there but not ours. Dart's `Process.killPid` cannot send
/// signal 0, and any real signal is a message: SIGUSR1's default action ends
/// the process, which is how a liveness probe once killed a host halfway
/// through its own graceful shutdown. Windows: `OpenProcess` for query, and
/// `STILL_ACTIVE` from `GetExitCodeProcess`.
bool processIsAlive(int pid) {
  if (pid <= 0) return false;
  return Platform.isWindows ? _aliveWindows(pid) : _alivePosix(pid);
}

bool _alivePosix(int pid) {
  final libc = Libc.open();
  if (libc.kill(pid, 0) == 0) return true;
  return libc.errno == _eperm;
}

bool _aliveWindows(int pid) {
  final k = Kernel32.open();
  final handle = k.openProcess(_processQueryLimitedInformation, 0, pid);
  if (handle == 0) return k.getLastError() == _errorAccessDenied;
  final code = calloc<Uint32>();
  try {
    if (k.getExitCodeProcess(handle, code) == 0) return true;
    return code.value == _stillActive;
  } finally {
    calloc.free(code);
    k.closeHandle(handle);
  }
}
