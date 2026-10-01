import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_files/values.dart';

import '../../environments/application/environment_values.dart';
import '../data/files_client.dart';

/// What the delete question needs to ask, and the delete itself, over the
/// server's file service — so the dialog that asks is not the code that
/// reaches the server.
class FileDeletion {
  const FileDeletion(this._files);

  final FilesClient _files;

  /// Whether [path] can go to a recycle bin rather than be deleted for good.
  bool canTrash(EnvironmentPath path) => _files.canTrash(path);

  /// How many entries [folder] holds, or null when it could not be listed.
  Future<int?> countIn(EnvironmentPath folder) async {
    try {
      return (await _files.list(folder)).length;
    } on FilesException {
      return null;
    }
  }

  /// Moves [entry] to the recycle bin ([toBin]) or deletes it. Null when it
  /// went; otherwise why it did not.
  Future<String?> remove(FileEntry entry, {required bool toBin}) async {
    try {
      if (toBin) {
        await _files.trash(entry.path);
      } else {
        await _files.delete(entry.path, recursive: entry.isDirectory);
      }
      return null;
    } on FilesException catch (error) {
      return error.message;
    }
  }
}

final fileDeletionProvider = Provider<FileDeletion>(
  (ref) => FileDeletion(ref.watch(filesClientProvider)),
);
