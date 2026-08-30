import '../../environments/domain/environment_path.dart';

/// What kind of thing a remote directory entry is.
enum RemoteEntryKind { directory, file, symlink, other }

/// One entry in a remote directory listing.
///
/// [path] is a full [EnvironmentPath] in the remote environment, never a bare
/// string: a listing of `/home/me/src` on `build-box` and the same text on the
/// local machine are different places, and the type keeps them apart
/// (principle 2).
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

/// Joins a POSIX [directory] and [name]. Remote paths are always POSIX, so this
/// never consults the host platform's separator — doing so is how a Windows
/// backslash ends up in a remote path.
String joinRemotePath(String directory, String name) {
  if (directory.isEmpty || directory == '/') return '/$name';
  final base = directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  return '$base/$name';
}
