import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/editor_language.dart';
import '../domain/source_document.dart';

/// How much of a file decides whether it is binary, and whether it is CRLF.
const int _sniffBytes = 8 * 1024;

final p.Context _hostPaths = p.windows;

/// Reads and writes one file on the Windows host — the same reach the file
/// listing has. Injectable so a test needs no real disk.
class DocumentStore {
  const DocumentStore();

  /// Never throws: what went wrong is a [DocumentRefusal] on the document,
  /// with the words to say it, because a blank pane explains nothing.
  Future<SourceDocument> load(String hostPath) async {
    final name = _hostPaths.basename(hostPath);
    try {
      final type = await FileSystemEntity.type(hostPath);
      if (type == FileSystemEntityType.notFound) {
        return _refused(
          hostPath,
          DocumentRefusal.notFound,
          '$name was not found at $hostPath.',
        );
      }
      if (type == FileSystemEntityType.directory) {
        return _refused(
          hostPath,
          DocumentRefusal.unreadable,
          '$name is a folder, not a file.',
        );
      }
      final file = File(hostPath);
      final stat = await file.stat();
      if (stat.size > kDocumentSizeLimit) {
        return _refused(
          hostPath,
          DocumentRefusal.tooLarge,
          '$name is ${_describeSize(stat.size)}, over the '
          '${_describeSize(kDocumentSizeLimit)} this editor opens.',
        );
      }
      final bytes = await file.readAsBytes();
      final sniffed = bytes.length < _sniffBytes ? bytes.length : _sniffBytes;
      for (var i = 0; i < sniffed; i++) {
        if (bytes[i] == 0) {
          return _refused(
            hostPath,
            DocumentRefusal.binary,
            '$name is a binary file — there is a NUL byte in it.',
          );
        }
      }
      final String decoded;
      try {
        decoded = utf8.decode(bytes);
      } on FormatException {
        return _refused(
          hostPath,
          DocumentRefusal.binary,
          '$name is not UTF-8 text.',
        );
      }
      final crlf = decoded
          .substring(
            0,
            decoded.length < _sniffBytes ? decoded.length : _sniffBytes,
          )
          .contains('\r\n');
      final text = crlf ? decoded.replaceAll('\r\n', '\n') : decoded;
      return SourceDocument(
        hostPath: hostPath,
        text: text,
        savedText: text,
        language: highlightLanguageFor(hostPath),
        stamp: FileStamp(length: stat.size, modified: stat.modified),
        crlf: crlf,
      );
    } on FileSystemException catch (error) {
      return _refused(
        hostPath,
        DocumentRefusal.unreadable,
        '$name could not be read: ${_reason(error)}',
      );
    }
  }

  /// What the file looks like now, or null when there is nothing there.
  Future<FileStamp?> stamp(String hostPath) async {
    final stat = await FileStat.stat(hostPath);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return FileStamp(length: stat.size, modified: stat.modified);
  }

  /// Throws [DocumentWriteException] with a readable message on failure. The
  /// stamp is read back off disk, so it is the one a later save compares to.
  Future<FileStamp> write(String hostPath, String text) async {
    final name = _hostPaths.basename(hostPath);
    // This editor edits files that exist; creating a tree for a typo'd path
    // would be a worse answer than refusing.
    final parent = _hostPaths.dirname(hostPath);
    if (parent.isNotEmpty && !await Directory(parent).exists()) {
      throw DocumentWriteException(
        '$name could not be saved: $parent does not exist.',
      );
    }
    try {
      await File(hostPath).writeAsString(text, flush: true);
    } on FileSystemException catch (error) {
      throw DocumentWriteException(
        '$name could not be saved: ${_reason(error)}',
      );
    }
    final written = await stamp(hostPath);
    if (written == null) {
      throw DocumentWriteException(
        '$name was written and then could not be found at $hostPath.',
      );
    }
    return written;
  }

  SourceDocument _refused(
    String hostPath,
    DocumentRefusal refusal,
    String error,
  ) => SourceDocument(
    hostPath: hostPath,
    text: '',
    savedText: '',
    refusal: refusal,
    error: error,
  );

  String _reason(FileSystemException error) =>
      error.osError?.message ?? error.message;

  String _describeSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes bytes';
  }
}

class DocumentWriteException implements Exception {
  const DocumentWriteException(this.message);

  final String message;

  @override
  String toString() => message;
}
