import 'package:agent_cli/process.dart';

/// Where `--vmservice-out-file` should point for a run in [kind], or null when
/// no path can be spelled that the run writes and the watcher reads.
///
/// WSL writes through `/mnt/c/…` so the file lands on the Windows disk: a
/// `Directory.watch` over `\\wsl.localhost` subscribes and never fires (§18).
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

/// A file name for one run, safe on every filesystem involved. [id] is what
/// keeps two runs of one project from overwriting each other.
String vmServiceOutFileName(String projectName, String id) =>
    '${projectName.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-')}-$id.uri';
