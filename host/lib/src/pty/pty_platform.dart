import 'dart:io';

import 'conpty.dart';
import 'posix_pty.dart';
import 'pty.dart';

/// A launcher for this machine, and the library it was found in.
///
/// Two implementations of one interface, chosen by the operating system and
/// nothing else — no setting, no environment variable. [library] is what the
/// host reports in `hello`: a reading taken here, never a guess made by the
/// client reading it.
class PtyPlatform {
  const PtyPlatform(this.launcher, this.library);
  final PtyLauncher launcher;
  final String library;
}

/// Throws [PtyException] naming what this machine could not provide. The caller
/// prints that sentence and refuses to serve, rather than starting a host whose
/// every `open` will fail one at a time.
PtyPlatform resolvePtyPlatform() {
  if (Platform.isWindows) {
    final ConPtyLauncher launcher;
    try {
      launcher = ConPtyLauncher();
    } on ArgumentError catch (e) {
      throw PtyException('no usable kernel32 on this machine: $e');
    }
    if (!launcher.providesPseudoConsole) {
      throw const PtyException(
        'this Windows has no ConPTY (CreatePseudoConsole arrived in 10 1809)',
      );
    }
    return PtyPlatform(launcher, launcher.ptyLibrary);
  }
  final PosixPtyLauncher launcher;
  try {
    launcher = PosixPtyLauncher();
  } on ArgumentError catch (e) {
    throw PtyException('no usable libc on this machine: $e');
  }
  return PtyPlatform(launcher, launcher.ptyLibrary);
}
