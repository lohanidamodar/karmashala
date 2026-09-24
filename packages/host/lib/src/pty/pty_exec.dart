import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// `TIOCSCTTY` on Darwin: `_IO('t', 97)`.
const int _kTiocsctty = 0x20007461;

/// `karmashala_host pty-exec -- <program> <args…>`: makes the pty on stdin
/// this session's controlling terminal, then becomes [program].
///
/// macOS never gives a session leader its controlling terminal on `open`, and
/// `posix_spawn` has no step that could ask for one — so without this a pane's
/// program had no terminal to be signalled through. The kernel delivers
/// `SIGWINCH` to a terminal's foreground group; with none, Claude Code never
/// heard of any resize and kept drawing at its first width (2026-09-24; `ps`
/// showed `??` for every child of the host). Linux takes the terminal on open
/// and never runs this.
///
/// Returns only when the exec failed; stderr is the pane, so the reason is
/// shown where the program would have been.
int runPtyExec(List<String> args) {
  final at = args.indexOf('--');
  final argv = at < 0 ? args : args.sublist(at + 1);
  if (argv.isEmpty) {
    stderr.writeln('karmashala_host pty-exec: nothing to run');
    return 2;
  }
  final libc = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  final ioctl = libc
      .lookup<
        NativeFunction<Int32 Function(Int32, UnsignedLong, VarArgs<(Int32,)>)>
      >('ioctl')
      .asFunction<int Function(int, int, int)>();
  final execv = libc
      .lookup<
        NativeFunction<Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)>
      >('execv')
      .asFunction<int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)>();
  final errno = libc
      .lookup<NativeFunction<Pointer<Int32> Function()>>('__error')
      .asFunction<Pointer<Int32> Function()>();

  // A failure here leaves the program without job control or resizes, which
  // is worse than today but not fatal, so it still runs.
  ioctl(0, _kTiocsctty, 0);

  final arena = Arena();
  try {
    final list = arena<Pointer<Utf8>>(argv.length + 1);
    for (var i = 0; i < argv.length; i++) {
      list[i] = argv[i].toNativeUtf8(allocator: arena);
    }
    list[argv.length] = nullptr;
    execv(list[0], list);
    stderr.writeln(
      'karmashala_host pty-exec: could not run ${argv.first} '
      '(errno ${errno().value})',
    );
    return 127;
  } finally {
    arena.releaseAll();
  }
}
