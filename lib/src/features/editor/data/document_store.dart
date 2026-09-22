import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../application/editor_language.dart';
import '../domain/document_id.dart';
import '../domain/document_source.dart';
import '../domain/source_document.dart';
import 'local_document_source.dart';

export '../domain/document_source.dart'
    show DocumentStaleException, DocumentUnreachableException, WriteExpectation;

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
/// BOM and CRLF round trip — over whichever [DocumentSource] its environment
/// has. Keyed by document id (`document_id.dart`), so every environment gets
/// the same rules. Injectable so a test needs no real disk.
class DocumentStore {
  const DocumentStore({this.sources});

  /// Null: this machine and WSL only, which need nothing but `dart:io`.
  final DocumentSourceResolver? sources;

  static final LocalDocumentSources _local = LocalDocumentSources();

  /// The source [documentId] is read through, or null when this build cannot
  /// reach its environment.
  DocumentSource? sourceOf(String documentId) =>
      (sources ?? _local).sourceFor(documentPathOf(documentId).environmentId);

  /// What the environment of [documentId] can do; null when it has no source.
  DocumentSourceCapabilities? capabilitiesOf(String documentId) =>
      sourceOf(documentId)?.capabilities;

  /// Never throws but for [DocumentUnreachableException]: what went wrong is a
  /// [DocumentRefusal] on the document, because a blank pane explains nothing.
  /// An environment that did not answer is not a fact about the file, so it is
  /// thrown for the caller to keep whatever buffer it has.
  Future<SourceDocument> load(String documentId) async {
    final at = documentPathOf(documentId);
    final name = documentNameOf(documentId);
    final source = sourceOf(documentId);
    if (source == null) {
      return _refused(
        documentId,
        DocumentRefusal.unreadable,
        'Karmashala cannot open files on "${at.environmentId}".',
      );
    }
    // Kept on a refusal too, so the disk check can tell "still binary" from
    // "rewritten as text" without reading it again.
    FileStamp? seen;
    try {
      final stat = await source.stat(at.path);
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
      seen = stat.version;
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
      final head = await source.read(at.path, length: _sniffBytes);
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
      var bytes = head.length < _sniffBytes ? head : await source.read(at.path);
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
    } on DocumentSourceException catch (error) {
      return _refused(
        documentId,
        DocumentRefusal.unreadable,
        '$name could not be read: ${error.message}',
        seen,
      );
    } on FileSystemException catch (error) {
      return _refused(
        documentId,
        DocumentRefusal.unreadable,
        '$name could not be read: ${_reason(error)}',
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
  /// Throws [DocumentUnreachableException] when its environment did not answer.
  Future<FileStamp?> stamp(String documentId) async {
    final source = sourceOf(documentId);
    if (source == null) {
      throw DocumentSourceException(
        'Karmashala cannot reach "${documentPathOf(documentId).environmentId}".',
      );
    }
    return (await source.stat(documentPathOf(documentId).path)).version;
  }

  /// Writes [text] if [expect] accepts what is on disk now. Answers the stamp
  /// read back off disk, the one a later save compares to. Throws
  /// [DocumentStaleException] when refused, [DocumentUnreachableException] when
  /// the environment dropped, and [DocumentWriteException] with a readable
  /// message for anything else.
  Future<FileStamp> write(
    String documentId,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    final name = documentNameOf(documentId);
    final source = sourceOf(documentId);
    if (source == null) {
      throw DocumentWriteException(
        '$name could not be saved: Karmashala cannot reach '
        '"${documentPathOf(documentId).environmentId}".',
      );
    }
    if (source.capabilities.readOnly) {
      throw DocumentWriteException('$name is read-only here.');
    }
    try {
      return await source.write(
        documentPathOf(documentId).path,
        utf8.encode(text),
        expect: expect,
      );
    } on DocumentSourceException catch (error) {
      throw DocumentWriteException(
        '$name could not be saved: ${error.message}',
      );
    } on FileSystemException catch (error) {
      throw DocumentWriteException(
        '$name could not be saved: ${_reason(error)}',
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
