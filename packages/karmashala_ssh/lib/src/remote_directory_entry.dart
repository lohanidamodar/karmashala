import 'package:agent_cli/process.dart';

/// What kind of thing a remote directory entry is.
enum RemoteEntryKind { directory, file, symlink, other }

/// One entry in a remote directory listing. [path] is a full [EnvironmentPath],
/// never a bare string: the same text names different places (principle 2).
class RemoteDirectoryEntry {
  const RemoteDirectoryEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.sizeBytes,
    this.modifiedAt,
  });

  final String name;
  final EnvironmentPath path;
  final RemoteEntryKind kind;
  final int? sizeBytes;
  final DateTime? modifiedAt;

  bool get isDirectory => kind == RemoteEntryKind.directory;

  /// Dotfiles, so a browser can hide them by default the way a file manager does.
  bool get isHidden => name.startsWith('.');

  @override
  String toString() => 'RemoteDirectoryEntry(${path.path}, ${kind.name})';
}

/// Joins a POSIX [directory] and [name], never consulting the host separator —
/// that is how a Windows backslash ends up in a remote path.
String joinRemotePath(String directory, String name) {
  if (directory.isEmpty || directory == '/') return '/$name';
  final base = directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  return '$base/$name';
}

/// The parent of a POSIX [directory], or null at the root: null is what lets a
/// browser disable "up" rather than offer a step that goes nowhere.
String? parentRemotePath(String directory) {
  if (directory.isEmpty || directory == '/') return null;
  final trimmed = directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  final cut = trimmed.lastIndexOf('/');
  if (cut < 0) return null;
  return cut == 0 ? '/' : trimmed.substring(0, cut);
}
