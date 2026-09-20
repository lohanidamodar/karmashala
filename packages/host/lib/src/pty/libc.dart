// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// `struct winsize` — the four shorts `ioctl(TIOCSWINSZ)` reads.
final class Winsize extends Struct {
  @Uint16()
  external int ws_row;
  @Uint16()
  external int ws_col;
  @Uint16()
  external int ws_xpixel;
  @Uint16()
  external int ws_ypixel;
}

/// Linux (x86_64 and arm64 alike) and macOS, which ships its own host bundle
/// since the release started carrying one. Values measured from the SDK headers
/// on macOS 26 arm64; the ioctl numbers encode the struct size, so they differ.
final int kTIOCSWINSZ = Platform.isMacOS ? 0x80087467 : 0x5414;
final int kTIOCGWINSZ = Platform.isMacOS ? 0x40087468 : 0x5413;
const int kOReadWrite = 2; // O_RDWR, the same on both
final int kPosixSpawnSetsid = Platform.isMacOS
    ? 0x400
    : 0x80; // POSIX_SPAWN_SETSID

/// glibc's `posix_spawnattr_t` is 336 bytes and `posix_spawn_file_actions_t` 80
/// on x86_64, both opaque; over-allocating survives a libc that grew them. On
/// Darwin both are a pointer (8 bytes, measured on arm64) that the `_init` calls
/// fill with their own allocation, so the buffer is larger than it needs to be
/// and still correct.
const int kOpaqueSpawnStructBytes = 1024;

typedef OpenptyNative =
    Int32 Function(
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Winsize>,
    );
typedef OpenptyDart =
    int Function(
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Winsize>,
    );

typedef IoctlWinsizeNative =
    Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Winsize>,)>);
typedef IoctlWinsizeDart = int Function(int, int, Pointer<Winsize>);

typedef PosixSpawnNative =
    Int32 Function(
      Pointer<Int32>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Pointer<Uint8>>,
    );
typedef PosixSpawnDart =
    int Function(
      Pointer<Int32>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Pointer<Uint8>>,
    );

/// Where the pty entry points were found: glibc 2.34 folded `libutil` into
/// `libc`, older ones did not.
enum PtySymbolSource { libc, libutil }

/// libc as this process sees it, plus the pty entry points wherever they live.
/// One instance per isolate: a `DynamicLibrary` cannot travel over a `SendPort`.
class Libc {
  Libc._(this._libc, this.ptySymbolSource, this.ptySymbolLibrary)
    : openpty = _resolveOpenpty(
        _libc,
        ptySymbolSource == PtySymbolSource.libc ? _libc : _util!,
      ),
      ioctlWinsize = _libc
          .lookup<NativeFunction<IoctlWinsizeNative>>('ioctl')
          .asFunction<IoctlWinsizeDart>(),
      posixSpawn = _libc
          .lookup<NativeFunction<PosixSpawnNative>>('posix_spawn')
          .asFunction<PosixSpawnDart>(),
      waitpid = _libc
          .lookup<NativeFunction<Int32 Function(Int32, Pointer<Int32>, Int32)>>(
            'waitpid',
          )
          .asFunction<int Function(int, Pointer<Int32>, int)>(),
      read = _libc
          .lookup<
            NativeFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr)>
          >('read')
          .asFunction<int Function(int, Pointer<Uint8>, int)>(),
      write = _libc
          .lookup<
            NativeFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr)>
          >('write')
          .asFunction<int Function(int, Pointer<Uint8>, int)>(),
      close = _libc
          .lookup<NativeFunction<Int32 Function(Int32)>>('close')
          .asFunction<int Function(int)>(),
      kill = _libc
          .lookup<NativeFunction<Int32 Function(Int32, Int32)>>('kill')
          .asFunction<int Function(int, int)>(),
      errnoLocation = _libc
          .lookup<NativeFunction<Pointer<Int32> Function()>>(
            Platform.isMacOS ? '__error' : '__errno_location',
          )
          .asFunction<Pointer<Int32> Function()>(),
      faInit = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
            'posix_spawn_file_actions_init',
          )
          .asFunction<int Function(Pointer<Void>)>(),
      faDestroy = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
            'posix_spawn_file_actions_destroy',
          )
          .asFunction<int Function(Pointer<Void>)>(),
      faAddOpen = _libc
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<Void>,
                Int32,
                Pointer<Uint8>,
                Int32,
                Uint32,
              )
            >
          >('posix_spawn_file_actions_addopen')
          .asFunction<
            int Function(Pointer<Void>, int, Pointer<Uint8>, int, int)
          >(),
      faAddDup2 = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32, Int32)>>(
            'posix_spawn_file_actions_adddup2',
          )
          .asFunction<int Function(Pointer<Void>, int, int)>(),
      faAddClose = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
            'posix_spawn_file_actions_addclose',
          )
          .asFunction<int Function(Pointer<Void>, int)>(),
      attrInit = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
            'posix_spawnattr_init',
          )
          .asFunction<int Function(Pointer<Void>)>(),
      attrDestroy = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
            'posix_spawnattr_destroy',
          )
          .asFunction<int Function(Pointer<Void>)>(),
      attrSetFlags = _libc
          .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int16)>>(
            'posix_spawnattr_setflags',
          )
          .asFunction<int Function(Pointer<Void>, int)>();

  final DynamicLibrary _libc;
  static DynamicLibrary? _util;

  /// Which library answered for `openpty`/`forkpty`, and its soname.
  final PtySymbolSource ptySymbolSource;
  final String ptySymbolLibrary;

  final OpenptyDart openpty;
  final IoctlWinsizeDart ioctlWinsize;
  final PosixSpawnDart posixSpawn;
  final int Function(int, Pointer<Int32>, int) waitpid;
  final int Function(int, Pointer<Uint8>, int) read;
  final int Function(int, Pointer<Uint8>, int) write;
  final int Function(int) close;
  final int Function(int, int) kill;
  final Pointer<Int32> Function() errnoLocation;
  final int Function(Pointer<Void>) faInit;
  final int Function(Pointer<Void>) faDestroy;
  final int Function(Pointer<Void>, int, Pointer<Uint8>, int, int) faAddOpen;
  final int Function(Pointer<Void>, int, int) faAddDup2;
  final int Function(Pointer<Void>, int) faAddClose;
  final int Function(Pointer<Void>) attrInit;
  final int Function(Pointer<Void>) attrDestroy;
  final int Function(Pointer<Void>, int) attrSetFlags;

  int get errno => errnoLocation().value;

  /// glibc 2.29+. Without it a host still runs sessions but refuses a working
  /// directory rather than starting the child in the wrong place.
  late final int Function(Pointer<Void>, Pointer<Uint8>)? faAddChdir = () {
    try {
      return _libc
          .lookup<
            NativeFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>)>
          >('posix_spawn_file_actions_addchdir_np')
          .asFunction<int Function(Pointer<Void>, Pointer<Uint8>)>();
    } on ArgumentError {
      return null;
    }
  }();

  static OpenptyDart _resolveOpenpty(
    DynamicLibrary libc,
    DynamicLibrary owner,
  ) => owner
      .lookup<NativeFunction<OpenptyNative>>('openpty')
      .asFunction<OpenptyDart>();

  static Libc? _instance;

  /// libc first, then `libutil.so.1`: on glibc >= 2.34 libutil is an empty stub,
  /// and on a host old enough to need it libc has no `openpty` at all.
  static Libc open() {
    final existing = _instance;
    if (existing != null) return existing;
    if (Platform.isMacOS) {
      // libSystem carries libc and libutil alike: openpty, posix_spawn, __error.
      const system = '/usr/lib/libSystem.B.dylib';
      return _instance = Libc._(
        DynamicLibrary.open(system),
        PtySymbolSource.libc,
        system,
      );
    }
    final libc = DynamicLibrary.open('libc.so.6');
    PtySymbolSource source;
    String library;
    if (libc.providesSymbol('openpty')) {
      source = PtySymbolSource.libc;
      library = 'libc.so.6';
    } else {
      _util = DynamicLibrary.open('libutil.so.1');
      source = PtySymbolSource.libutil;
      library = 'libutil.so.1';
    }
    return _instance = Libc._(libc, source, library);
  }

  /// Looked up, never called: after `fork` in a multithreaded VM only
  /// async-signal-safe code is legal and returning into Dart is not.
  bool get providesForkpty =>
      _libc.providesSymbol('forkpty') ||
      (_util?.providesSymbol('forkpty') ?? false);
}

/// Zero-terminated bytes for a C string parameter, owned by [alloc].
Pointer<Uint8> cString(Allocator alloc, String value) =>
    value.toNativeUtf8(allocator: alloc).cast<Uint8>();
