import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _QueryNative = Int32 Function(Pointer<Int32> state);
typedef _Query = int Function(Pointer<Int32> state);

/// `QUNS_ACCEPTS_NOTIFICATIONS`: the one state in which Windows takes them.
const int _acceptsNotifications = 5;

_Query? _query;

/// Whether the OS asks for quiet now — do not disturb, a presentation, a
/// full-screen app — as Windows' `SHQueryUserNotificationState` reports it.
/// Null where nothing reads it: another OS, or a call that failed.
bool? osAsksForQuiet() {
  if (!Platform.isWindows) return null;
  try {
    final query = _query ??= DynamicLibrary.open(
      'shell32.dll',
    ).lookupFunction<_QueryNative, _Query>('SHQueryUserNotificationState');
    final state = calloc<Int32>();
    try {
      if (query(state) != 0) return null;
      return state.value != _acceptsNotifications;
    } finally {
      calloc.free(state);
    }
  } on Object {
    return null;
  }
}
