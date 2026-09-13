import 'package:path/path.dart' as p;

/// Over this a file opens read-only ([DocumentMode.view]): the editable field
/// lays the whole buffer out as one paragraph — tool/benchmark/code_field_bench.dart.
const int kEditableSizeLimit = 512 * 1024;

/// Over this a file does not open at all: a viewer's drawing does not care
/// about length, but reading the bytes and splitting them does.
const int kDocumentSizeLimit = 64 * 1024 * 1024;

/// Over this the buffer is drawn in plain mono: one `highlight.parse` of the
/// whole file is linear and runs on every change.
const int kHighlightSizeLimit = 256 * 1024;

/// Host paths are spelled for Windows, and a UNC share is one of them; asking
/// the windows context keeps the answer right on a machine that is not.
final p.Context _hostPaths = p.windows;

/// Why a file will not open, or [none].
enum DocumentRefusal { none, notFound, unreadable, binary, tooLarge }

/// How a file can be opened.
enum DocumentMode {
  /// Small enough to edit: the full field, highlighting, saving.
  edit,

  /// Too big to edit at a usable speed, so it opens read-only in a viewer that
  /// draws only the lines on screen. Nothing about it is broken; editing it
  /// here would be.
  view,
}

/// What a file looked like when it was read — what a save checks before it
/// overwrites. Null [modified] means the filesystem did not say.
class FileStamp {
  const FileStamp({required this.length, required this.modified});

  final int length;
  final DateTime? modified;

  /// Whether [other] is the same file we read. A missing modification time is
  /// not evidence of a change, so length decides alone (§19).
  bool matches(FileStamp? other) {
    if (other == null) return false;
    if (other.length != length) return false;
    final mine = modified;
    final theirs = other.modified;
    if (mine == null || theirs == null) return true;
    return mine == theirs;
  }

  @override
  bool operator ==(Object other) =>
      other is FileStamp &&
      other.length == length &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(length, modified);

  @override
  String toString() => 'FileStamp($length, $modified)';
}

/// One open file: the bytes as they were read, the bytes as they are now, and
/// what was refused instead.
class SourceDocument {
  const SourceDocument({
    required this.hostPath,
    required this.text,
    required this.savedText,
    this.language,
    this.stamp,
    this.refusal = DocumentRefusal.none,
    this.error,
    this.crlf = false,
    this.bom = false,
    this.mode = DocumentMode.edit,
  });

  final String hostPath;
  final String text;
  final String savedText;

  /// The `highlight` language id, or null when the extension names none.
  final String? language;

  final FileStamp? stamp;
  final DocumentRefusal refusal;

  /// The reason, in words the UI shows. Non-null exactly when refused.
  final String? error;

  /// Whether the file on disk uses CRLF. The buffer is always LF; a save puts
  /// the file's own endings back rather than rewriting every line.
  final bool crlf;

  /// Whether the file on disk began with a UTF-8 BOM. The buffer never holds
  /// it; a save writes it back rather than silently dropping it.
  final bool bom;

  final DocumentMode mode;

  /// The file's own name, for a tab title.
  String get name => _hostPaths.basename(hostPath);

  bool get isDirty => text != savedText;

  bool get isReadable => refusal == DocumentRefusal.none;

  /// Whether it opened small enough to type into — see [kEditableSizeLimit].
  bool get isEditable => mode == DocumentMode.edit;

  /// Whether it is small enough to colour — see [kHighlightSizeLimit].
  bool get canHighlight => isReadable && text.length <= kHighlightSizeLimit;

  /// The buffer as bytes for this file: the BOM and CRLF it came with, back.
  String get diskText {
    final lines = crlf ? text.replaceAll('\n', '\r\n') : text;
    return bom ? '\u{FEFF}$lines' : lines;
  }

  SourceDocument withText(String next) => _copy(text: next);

  SourceDocument asSaved(FileStamp stamp) =>
      _copy(savedText: text, stamp: stamp);

  SourceDocument _copy({String? text, String? savedText, FileStamp? stamp}) =>
      SourceDocument(
        hostPath: hostPath,
        text: text ?? this.text,
        savedText: savedText ?? this.savedText,
        language: language,
        stamp: stamp ?? this.stamp,
        refusal: refusal,
        error: error,
        crlf: crlf,
        bom: bom,
        mode: mode,
      );
}
