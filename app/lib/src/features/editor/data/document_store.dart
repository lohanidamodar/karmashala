import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_files/values.dart' show WriteExpectation;

import '../../files/data/files_client.dart';
import '../application/editor_language.dart';
import '../domain/document_id.dart';
import '../domain/source_document.dart';

export 'package:karmashala_files/values.dart' show WriteExpectation;

export '../../files/data/files_client.dart'
    show FilesStaleException, FilesUnreachableException;

/// How much of a file decides whether it is binary, and whether it is CRLF.
const int _sniffBytes = 8 * 1024;

/// VS Code's own wording, and the honest one: the two cannot be told apart.
const String _binaryFileMessage =
    'The file is not displayed in the editor because it is either binary or '
    'uses an unsupported text encoding.';

const List<int> _utf8Bom = [0xef, 0xbb, 0xbf];
const List<int> _utf16LeBom = [0xff, 0xfe];
const List<int> _utf16BeBom = [0xfe, 0xff];

/// Reads and writes one document — decoding, the size and binary refusals, the
/// BOM and CRLF round trip — through the server, wherever its environment is
/// (slice 3c): the bytes are the server's to read and write, the text is this
/// editor's. Keyed by document id (`document_id.dart`), so every environment
/// gets the same rules.
class DocumentStore {
  const DocumentStore(this.files);

  final FilesClient files;

  /// Never throws but for [FilesUnreachableException]: what went wrong is a
  /// [DocumentRefusal] on the document, because a blank pane explains nothing.
  /// An environment that did not answer is not a fact about the file, so it is
  /// thrown for the caller to keep whatever buffer it has.
  Future<SourceDocument> load(String documentId) async {
    final at = documentPathOf(documentId);
    final name = documentNameOf(documentId);
    // Kept on a refusal too, so the disk check can tell "still binary" from
    // "rewritten as text" without reading it again.
    FileStamp? seen;
    try {
      final stat = await files.stat(at);
      if (!stat.exists) {
        return _refused(
          documentId,
          DocumentRefusal.notFound,
          '$name was not found at ${at.path}.',
        );
      }
      if (stat.isDirectory) {
        return _refused(
          documentId,
          DocumentRefusal.unreadable,
          '$name is a folder, not a file.',
        );
      }
      seen = stat.stamp;
      if (stat.size > kDocumentSizeLimit) {
        return _refused(
          documentId,
          DocumentRefusal.tooLarge,
          '$name is ${_describeSize(stat.size)}, over the '
          '${_describeSize(kDocumentSizeLimit)} this editor opens.',
          seen,
        );
      }
      // The head alone answers "is this text?", so a 64 MB binary never
      // reaches memory.
      final head = await files.read(at, length: _sniffBytes);
      if (_startsWith(head, _utf16LeBom) || _startsWith(head, _utf16BeBom)) {
        return _refused(
          documentId,
          DocumentRefusal.binary,
          _binaryFileMessage,
          seen,
        );
      }
      final bom = _startsWith(head, _utf8Bom);
      for (final byte in head) {
        if (byte == 0) {
          return _refused(
            documentId,
            DocumentRefusal.binary,
            _binaryFileMessage,
            seen,
          );
        }
      }
      // A head shorter than asked for is the whole file: over SSH that is a
      // round trip saved on nearly every source file.
      var bytes = head.length < _sniffBytes ? head : await files.read(at);
      if (bom) bytes = Uint8List.sublistView(bytes, _utf8Bom.length);
      final String decoded;
      try {
        decoded = utf8.decode(bytes);
      } on FormatException {
        return _refused(
          documentId,
          DocumentRefusal.binary,
          _binaryFileMessage,
          seen,
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
        hostPath: documentId,
        text: text,
        savedText: text,
        language: highlightLanguageFor(at.path),
        stamp: seen,
        crlf: crlf,
        bom: bom,
        mode: stat.size > kEditableSizeLimit
            ? DocumentMode.view
            : DocumentMode.edit,
      );
    } on FilesUnreachableException {
      rethrow;
    } on FilesException catch (error) {
      return _refused(
        documentId,
        DocumentRefusal.unreadable,
        '$name could not be read: ${error.message}',
        seen,
      );
    }
  }

  bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// What the file looks like now, or null when there is nothing there.
  /// Throws [FilesUnreachableException] when its environment did not answer.
  Future<FileStamp?> stamp(String documentId) async =>
      (await files.stat(documentPathOf(documentId))).stamp;

  /// Writes [text] if [expect] accepts what is on disk now. Answers the stamp
  /// read back off disk, the one a later save compares to. Throws
  /// [FilesStaleException] when refused, [FilesUnreachableException] when the
  /// environment dropped, and [DocumentWriteException] with a readable
  /// message for anything else.
  Future<FileStamp> write(
    String documentId,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    final name = documentNameOf(documentId);
    try {
      return await files.write(
        documentPathOf(documentId),
        utf8.encode(text),
        expect: expect,
      );
    } on FilesStaleException {
      rethrow;
    } on FilesUnreachableException {
      rethrow;
    } on FilesException catch (error) {
      throw DocumentWriteException(
        '$name could not be saved: ${error.message}',
      );
    }
  }

  SourceDocument _refused(
    String documentId,
    DocumentRefusal refusal,
    String error, [
    FileStamp? stamp,
  ]) => SourceDocument(
    hostPath: documentId,
    text: '',
    savedText: '',
    stamp: stamp,
    refusal: refusal,
    error: error,
  );

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
