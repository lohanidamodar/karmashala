/// Whether a directory entry is one the user asked not to see.
///
/// Two conventions, because two are in use: a leading dot everywhere, and the
/// Windows hidden and system attributes. `dart:io` cannot answer the second —
/// `FileStat.mode` is emulated on Windows and carries no attribute bits — so
/// that half goes through `GetFileAttributesW`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

const int _invalidFileAttributes = 0xFFFFFFFF;
const int _attributeHidden = 0x2;
const int _attributeSystem = 0x4;

typedef _GetFileAttributesC = Uint32 Function(Pointer<Uint16>);
typedef _GetFileAttributesDart = int Function(Pointer<Uint16>);

_GetFileAttributesDart? _getFileAttributes;
bool _looked = false;

_GetFileAttributesDart? _resolve() {
  if (_looked) return _getFileAttributes;
  _looked = true;
  if (!Platform.isWindows) return null;
  try {
    _getFileAttributes = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_GetFileAttributesC, _GetFileAttributesDart>(
          'GetFileAttributesW',
        );
  } on Object {
    // A kernel32 that will not answer is not worth a broken listing; every
    // entry then falls back to the leading-dot rule alone.
    _getFileAttributes = null;
  }
  return _getFileAttributes;
}

/// Whether [name] at [path] is hidden. Unknowable answers are **false**: a file
/// the check could not classify must stay visible, because a listing that
/// silently drops a row is worse than one with a row too many.
bool isHiddenEntry({
  required String name,
  required String path,
  @visibleForTesting bool? windowsHidden,
}) {
  if (name.startsWith('.')) return true;
  if (windowsHidden != null) return windowsHidden;
  return hasWindowsHiddenAttribute(path);
}

/// The Windows hidden or system attribute, or false anywhere else.
bool hasWindowsHiddenAttribute(String path) {
  final lookup = _resolve();
  if (lookup == null) return false;
  Pointer<Uint16>? wide;
  try {
    wide = path.toNativeUtf16().cast<Uint16>();
    final attributes = lookup(wide);
    if (attributes == _invalidFileAttributes) return false;
    return attributes & (_attributeHidden | _attributeSystem) != 0;
  } on Object {
    return false;
  } finally {
    if (wide != null) malloc.free(wide);
  }
}

/// Whether browsers show hidden entries, as **one** answer for all of them.
///
/// The app's picker, the SSH browser and the device's own file manager each had
/// their own idea — one hid dotfiles, one had a toggle, one showed everything —
/// so the same folder read three ways. The app installs [read] and [write] from
/// settings at start-up; without them the choice still works, it just lasts
/// only as long as the process, which is what a test and the phone want.
class HiddenFilesPreference {
  const HiddenFilesPreference._();

  static bool Function()? read;
  static void Function(bool value)? write;

  static bool _remembered = false;

  /// Whether hidden entries are shown right now.
  static bool get shown {
    try {
      return read?.call() ?? _remembered;
    } on Object {
      return _remembered;
    }
  }

  /// Records the choice, persisting it when the app has wired [write].
  static void choose(bool value) {
    _remembered = value;
    try {
      write?.call(value);
    } on Object {
      // A settings write that fails must not cost the user the toggle.
    }
  }

  /// For a test that has to start from a known answer.
  @visibleForTesting
  static void reset() {
    read = null;
    write = null;
    _remembered = false;
  }
}
