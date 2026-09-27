import 'dart:io';

/// Which build of `karmashala_host` [executablePath] is: its size and when it
/// was written. `kHostVersion` is the same string in every build, so this is
/// what tells the host an app ships from one an earlier app left running.
/// Null when the file cannot be read, which is unknown, never a mismatch.
String? hostBuildOf(String executablePath) {
  try {
    final stat = File(executablePath).statSync();
    if (stat.type != FileSystemEntityType.file) return null;
    return '${stat.size}-${stat.modified.toUtc().millisecondsSinceEpoch}';
  } on FileSystemException {
    return null;
  }
}
