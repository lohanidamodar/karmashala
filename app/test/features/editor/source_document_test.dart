import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';

SourceDocument _doc({
  String hostPath = r'C:\src\app\lib\main.dart',
  String text = 'void main() {}\n',
  String? savedText,
  bool crlf = false,
  bool bom = false,
  DocumentMode mode = DocumentMode.edit,
}) => SourceDocument(
  hostPath: hostPath,
  text: text,
  savedText: savedText ?? text,
  language: 'dart',
  stamp: const FileStamp(length: 15, modified: null),
  crlf: crlf,
  bom: bom,
  mode: mode,
);

void main() {
  group('what a document says about itself', () {
    test('its name is the file name, on either separator', () {
      expect(_doc().name, 'main.dart');
      expect(
        _doc(hostPath: r'\\wsl.localhost\arch\home\d\a b\notes: draft.md').name,
        'notes: draft.md',
      );
      expect(_doc(hostPath: '/home/d/app/main.dart').name, 'main.dart');
    });

    test('it is dirty exactly when the buffer left the saved bytes', () {
      final clean = _doc();
      expect(clean.isDirty, isFalse);
      final edited = clean.withText('void main() { print(1); }\n');
      expect(edited.isDirty, isTrue);
      expect(edited.withText(clean.text).isDirty, isFalse);
    });

    test(
      'a save makes the buffer the saved bytes, and takes the new stamp',
      () {
        final edited = _doc().withText('edited\n');
        const stamp = FileStamp(length: 7, modified: null);
        final saved = edited.asSaved(stamp);
        expect(saved.isDirty, isFalse);
        expect(saved.savedText, 'edited\n');
        expect(saved.stamp, stamp);
        expect(saved.language, 'dart');
      },
    );

    test('a refusal is readable and carries its reason', () {
      const refused = SourceDocument(
        hostPath: r'C:\src\app\big.bin',
        text: '',
        savedText: '',
        refusal: DocumentRefusal.binary,
        error: 'big.bin is a binary file.',
      );
      expect(refused.isReadable, isFalse);
      expect(refused.canHighlight, isFalse);
      expect(refused.isDirty, isFalse);
      expect(_doc().isReadable, isTrue);
      expect(_doc().error, isNull);
    });

    test('it stops being worth colouring above the highlight limit', () {
      expect(_doc().canHighlight, isTrue);
      expect(_doc(text: 'x' * kHighlightSizeLimit).canHighlight, isTrue);
      expect(_doc(text: 'x' * (kHighlightSizeLimit + 1)).canHighlight, isFalse);
      expect(kHighlightSizeLimit, lessThan(kEditableSizeLimit));
      expect(kEditableSizeLimit, lessThan(kDocumentSizeLimit));
    });

    test('it is editable unless it was opened to be viewed', () {
      expect(_doc().mode, DocumentMode.edit);
      expect(_doc().isEditable, isTrue);

      final viewer = _doc(mode: DocumentMode.view);
      expect(viewer.isEditable, isFalse);
      expect(viewer.isReadable, isTrue);
      expect(viewer.canHighlight, isTrue);
    });

    test('an edit and a save carry the mode and the BOM along', () {
      final viewer = _doc(mode: DocumentMode.view, bom: true, crlf: true);

      final edited = viewer.withText('other\n');
      expect(edited.mode, DocumentMode.view);
      expect(edited.bom, isTrue);
      expect(edited.crlf, isTrue);

      final saved = edited.asSaved(const FileStamp(length: 6, modified: null));
      expect(saved.mode, DocumentMode.view);
      expect(saved.bom, isTrue);
      expect(saved.crlf, isTrue);
    });

    test('a file that had a BOM gets it back on the way to disk', () {
      expect(_doc(text: 'a\nb\n', bom: true).diskText, '\u{FEFF}a\nb\n');
      expect(
        _doc(text: 'a\nb\n', bom: true, crlf: true).diskText,
        '\u{FEFF}a\r\nb\r\n',
      );
      expect(_doc(text: 'a\nb\n').diskText, 'a\nb\n');
    });

    test('a CRLF file gets its endings back on the way to disk', () {
      final crlf = _doc(text: 'a\nb\n', crlf: true);
      expect(crlf.text, 'a\nb\n');
      expect(crlf.diskText, 'a\r\nb\r\n');
      expect(crlf.withText('a\nb\nc\n').diskText, 'a\r\nb\r\nc\r\n');
      expect(_doc(text: 'a\nb\n').diskText, 'a\nb\n');
    });
  });

  group('a stamp', () {
    final noon = DateTime.utc(2026, 9, 13, 12);

    test('matches only the file it was taken from', () {
      final stamp = FileStamp(length: 10, modified: noon);
      expect(stamp.matches(FileStamp(length: 10, modified: noon)), isTrue);
      expect(stamp.matches(FileStamp(length: 11, modified: noon)), isFalse);
      expect(
        stamp.matches(
          FileStamp(length: 10, modified: noon.add(const Duration(seconds: 1))),
        ),
        isFalse,
      );
      expect(stamp.matches(null), isFalse);
    });

    test('an unsaid modification time is not evidence of a change', () {
      final stamp = FileStamp(length: 10, modified: noon);
      expect(
        stamp.matches(const FileStamp(length: 10, modified: null)),
        isTrue,
      );
      expect(
        stamp.matches(const FileStamp(length: 11, modified: null)),
        isFalse,
      );
    });

    test('is a value', () {
      expect(
        FileStamp(length: 10, modified: noon),
        FileStamp(length: 10, modified: noon),
      );
      expect(
        FileStamp(length: 10, modified: noon).hashCode,
        FileStamp(length: 10, modified: noon).hashCode,
      );
      expect(
        FileStamp(length: 10, modified: noon),
        isNot(const FileStamp(length: 10, modified: null)),
      );
    });
  });
}
