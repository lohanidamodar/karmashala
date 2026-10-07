import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;

import '../../files/data/files_client.dart';
import '../domain/file_preview_kind.dart';

/// What an inline preview found at a path: the head of the file, or why there
/// is nothing to show.
class FilePreviewData {
  const FilePreviewData({
    required this.kind,
    this.size = 0,
    this.bytes,
    this.cut = false,
    this.missing = false,
    this.directory = false,
    this.tooLarge = false,
    this.binary = false,
  });

  final FilePreviewKind kind;
  final int size;

  /// The bytes read: the whole file, or its first [kPreviewTextBytes] when
  /// [cut].
  final Uint8List? bytes;
  final bool cut;
  final bool missing;
  final bool directory;

  /// A picture or PDF past [kPreviewMediaBytes]: not read at all.
  final bool tooLarge;

  /// Named like text, but its head holds a NUL byte.
  final bool binary;
}

/// Reads a file for a preview through the server, wherever the file is: this
/// machine, a WSL distribution or an SSH host.
class FilePreviewLoader {
  FilePreviewLoader(this._files);

  final FilesClient _files;

  /// Throws [FilesException] when the server cannot reach the file.
  Future<FilePreviewData> load(EnvironmentPath path) async {
    final kind = previewKindFor(path.path);
    final stat = await _files.stat(path);
    if (!stat.exists) {
      return FilePreviewData(kind: kind, missing: true);
    }
    if (stat.isDirectory) return FilePreviewData(kind: kind, directory: true);
    final size = stat.size;
    if (kind == FilePreviewKind.other) {
      return FilePreviewData(kind: kind, size: size);
    }
    if (!isTextPreview(kind)) {
      if (size > kPreviewMediaBytes) {
        return FilePreviewData(kind: kind, size: size, tooLarge: true);
      }
      final bytes = await _files.read(path);
      return FilePreviewData(kind: kind, size: size, bytes: bytes);
    }
    final bytes = await _files.read(path, length: kPreviewTextBytes);
    if (looksBinary(bytes)) {
      return FilePreviewData(kind: kind, size: size, binary: true);
    }
    return FilePreviewData(
      kind: kind,
      size: size,
      bytes: bytes,
      cut: size > bytes.length,
    );
  }
}

final filePreviewLoaderProvider = Provider<FilePreviewLoader>(
  (ref) => FilePreviewLoader(ref.watch(filesClientProvider)),
);
