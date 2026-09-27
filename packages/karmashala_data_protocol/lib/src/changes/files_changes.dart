part of '../data_change.dart';

// What a watched path did (slice 3c). Told only to the link that watches it
// (`files.watch`), never to every client: a file open in one window is
// nobody else's business.

DataChange? _filesChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'fileChanged' => FileChanged(
        environmentId: json['environmentId']! as String,
        path: json['path']! as String,
        stamp: json['stamp'] == null
            ? null
            : FileStamp.fromJson((json['stamp']! as Map).cast()),
      ),
      _ => null,
    };

/// A change to a machine's files a client asked to be told of.
sealed class FilesChange extends DataChange {
  const FilesChange();
}

/// The file or folder at [path] in [environmentId] changed on disk: its
/// [stamp] now — a folder's moves when an entry comes or goes — or null when
/// it is gone.
final class FileChanged extends FilesChange {
  const FileChanged({
    required this.environmentId,
    required this.path,
    required this.stamp,
  });

  final String environmentId;
  final String path;
  final FileStamp? stamp;

  EnvironmentPath get at =>
      EnvironmentPath(environmentId: environmentId, path: path);

  @override
  Map<String, Object?> toJson() => {
    'change': 'fileChanged',
    'environmentId': environmentId,
    'path': path,
    'stamp': ?stamp?.toJson(),
  };
}
