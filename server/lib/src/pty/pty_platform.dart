import 'dart:io';

import 'conpty.dart';
import 'posix_pty.dart';
import 'pty.dart';

/// A launcher for this machine, chosen by the operating system and nothing else.
/// [library] is what `hello` reports — measured here, never guessed by a client.
class PtyPlatform {
  const PtyPlatform(this.launcher, this.library);
  final PtyLauncher launcher;
  final String library;
}

/// Throws [PtyException] naming what this machine could not provide, so the
/// caller refuses to serve rather than failing one `open` at a time.
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
