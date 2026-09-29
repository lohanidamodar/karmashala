/// This machine's recycle bin, for `files.trash`: Windows only, where the
/// shell's `SHFileOperationW` moves a file or a whole folder into it.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Whether [hostPath] — spelled for `dart:io` on this machine — can go to a
/// recycle bin: a drive path on Windows. A `\\server\share` path, which is
/// how a WSL distribution's files are reached, has no bin; the shell would
/// delete it outright.
bool canRecycle(String hostPath) =>
    Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(hostPath);

/// Moves [hostPath] to the recycle bin. Throws [RecycleBinException] with a
/// sentence when it did not go. Runs off the server's event loop: the shell
/// takes a while over a big folder.
Future<void> moveToRecycleBin(String hostPath) async {
  if (!canRecycle(hostPath)) {
    throw RecycleBinException('$hostPath has no recycle bin to go to.');
  }
  final failure = await Isolate.run(() => _recycle(hostPath));
  if (failure != null) throw RecycleBinException(failure);
}

class RecycleBinException implements Exception {
  const RecycleBinException(this.message);

  final String message;

  @override
  String toString() => 'RecycleBinException: $message';
}

const int _foDelete = 0x3;
const int _fofSilent = 0x4;
const int _fofNoConfirmation = 0x10;
const int _fofAllowUndo = 0x40;
const int _fofNoErrorUi = 0x400;

/// Asks before destroying anything the bin will not take (too big for it, or
/// the bin switched off on that drive) — the one prompt left on, because the
/// person chose the recycle bin, not a permanent delete.
const int _fofWantNukeWarning = 0x4000;

/// `SHFILEOPSTRUCTW`, x64 layout (natural alignment; shellapi.h packs it to 1
/// only on 32-bit).
final class _ShFileOpStruct extends Struct {
  external Pointer<Void> hwnd;

  @Uint32()
  external int wFunc;

  external Pointer<Uint16> pFrom;
  external Pointer<Uint16> pTo;

  @Uint16()
  external int fFlags;

  @Int32()
  external int fAnyOperationsAborted;

  external Pointer<Void> hNameMappings;
  external Pointer<Uint16> lpszProgressTitle;
}

typedef _ShFileOperationC = Int32 Function(Pointer<_ShFileOpStruct>);
typedef _ShFileOperationDart = int Function(Pointer<_ShFileOpStruct>);

/// Null when it went; otherwise why not.
String? _recycle(String hostPath) {
  final full = File(hostPath).absolute.path;
  final _ShFileOperationDart operate;
  try {
    operate = DynamicLibrary.open('shell32.dll')
        .lookupFunction<_ShFileOperationC, _ShFileOperationDart>(
          'SHFileOperationW',
        );
  } on Object catch (error) {
    return 'the recycle bin could not be reached ($error).';
  }
  // pFrom is a list of paths ended by an empty one: two NULs at the end.
  final units = full.codeUnits;
  final from = calloc<Uint16>(units.length + 2);
  final op = calloc<_ShFileOpStruct>();
  try {
    for (var i = 0; i < units.length; i++) {
      from[i] = units[i];
    }
    op.ref
      ..wFunc = _foDelete
      ..pFrom = from
      ..fFlags =
          _fofAllowUndo |
          _fofNoConfirmation |
          _fofSilent |
          _fofNoErrorUi |
          _fofWantNukeWarning;
    final result = operate(op);
    if (op.ref.fAnyOperationsAborted != 0) {
      return 'it was not moved to the recycle bin (cancelled).';
    }
    if (result != 0) {
      return 'the recycle bin refused it (error 0x${result.toRadixString(16)}).';
    }
    if (FileSystemEntity.typeSync(full, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return 'it is still there after the move to the recycle bin.';
    }
    return null;
  } finally {
    calloc.free(from);
    calloc.free(op);
  }
}
