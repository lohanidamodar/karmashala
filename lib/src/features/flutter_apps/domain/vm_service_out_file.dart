import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_kind.dart';

/// Where `--vmservice-out-file` should point for a run in [kind], given the
/// **host** directory this app watches — or null when no path can be spelled
/// that the run can write and the watcher can read.
///
/// This is the whole of the auto-attach mechanism's addressing, and each kind
/// answers differently for a reason §18 measured:
///
/// * **Windows and the local POSIX host** are the machine doing the watching.
///   The directory as it stands.
/// * **WSL** writes through the drive mount — `/mnt/c/…` — so the file lands on
///   the *Windows* disk and the Windows watcher fires. The other way round does
///   not work: `Directory.watch` over `\\wsl.localhost` subscribes and never
///   fires, so a file on the distribution's own disk would be invisible until
///   somebody looked.
/// * **SSH** is another machine's disk, and its VM service is not reachable
///   from here either. Null, and the run still happens — the pane is the
///   report.
String? vmServiceOutFileFor({
  required EnvironmentKind kind,
  required String directory,
  required String name,
}) {
  switch (kind) {
    case EnvironmentKind.windowsNative:
      final base = directory.replaceAll(RegExp(r'[\\/]+$'), '');
      return '$base\\$name';
    case EnvironmentKind.localPosix:
      final base = directory.replaceAll(RegExp(r'/+$'), '');
      return '$base/$name';
    case EnvironmentKind.wsl:
      try {
        final mount = const PathTranslator().windowsDriveToWslMount(directory);
        return '$mount/$name';
      } on PathTranslationException {
        return null;
      }
    case EnvironmentKind.ssh:
      return null;
  }
}

/// The same file as this host spells it, so it can be read back — or null when
/// it is not on this host at all.
String? hostSpellingOfOutFile(String path) {
  if (!path.startsWith('/mnt/')) return path;
  try {
    return const PathTranslator().wslMountToWindowsDrive(path);
  } on PathTranslationException {
    return null;
  }
}

/// A file name for one run, safe on every filesystem involved.
///
/// The project's name so a directory of them is readable, and [id] so two runs
/// of one project — a phone and a simulator, which is an ordinary pair — are
/// two files rather than one overwriting the other.
String vmServiceOutFileName(String projectName, String id) =>
    '${projectName.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-')}-$id.uri';
