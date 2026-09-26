import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:path/path.dart' as p;

const _binaryMessage =
    'The file is not displayed in the editor because it is either binary or '
    'uses an unsupported text encoding.';

/// A file of [size] bytes without writing [size] bytes.
void _sizedFile(String path, int size) {
  final handle = File(path).openSync(mode: FileMode.write);
  try {
    handle.truncateSync(size);
  } finally {
    handle.closeSync();
  }
}

void main() {
  late Directory dir;
  const store = DocumentStore();

  String at(String name) => p.join(dir.path, name);

  setUp(() => dir = Directory.systemTemp.createTempSync('karmashala_editor_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('reading a file', () {
    test(
      'a text file arrives whole, with its language and its stamp',
      () async {
        final path = at('main.dart');
        File(path).writeAsStringSync('void main() {}\n');

        final doc = await store.load(path);

        expect(doc.refusal, DocumentRefusal.none);
        expect(doc.error, isNull);
        expect(doc.isReadable, isTrue);
        expect(doc.text, 'void main() {}\n');
        expect(doc.savedText, doc.text);
        expect(doc.isDirty, isFalse);
        expect(doc.language, 'dart');
        expect(doc.name, 'main.dart');
        expect(doc.stamp, isNotNull);
        expect(doc.stamp!.length, 15);
        expect(doc.stamp!.modified, isNotNull);
      },
    );

    test('a file whose extension names no language still opens', () async {
      final path = at('notes.txt');
      File(path).writeAsStringSync('hello');

      final doc = await store.load(path);

      expect(doc.isReadable, isTrue);
      expect(doc.language, isNull);
      expect(doc.text, 'hello');
    });

    test('over the size limit it refuses and says how big', () async {
      final path = at('huge.dart');
      _sizedFile(path, kDocumentSizeLimit + 16 * 1024 * 1024);

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.tooLarge);
      expect(doc.isReadable, isFalse);
      expect(doc.text, isEmpty);
      expect(doc.error, contains('huge.dart'));
      expect(doc.error, contains('80.0 MB'));
      expect(doc.error, contains('64.0 MB'));
    });

    test('a NUL byte makes it binary', () async {
      final path = at('a.bin');
      File(path).writeAsBytesSync(Uint8List.fromList([0x61, 0x00, 0x62]));

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.binary);
      expect(doc.error, _binaryMessage);
    });

    test('a NUL past the sniffed head is not looked for', () async {
      final path = at('late.dart');
      final bytes = Uint8List(9 * 1024)..fillRange(0, 9 * 1024, 0x61);
      bytes[8 * 1024 + 10] = 0;
      File(path).writeAsBytesSync(bytes);

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.none);
      expect(doc.text.length, 9 * 1024);
    });

    test('bytes that are not UTF-8 make it binary too', () async {
      final path = at('b.dart');
      File(path).writeAsBytesSync(Uint8List.fromList([0x61, 0xff, 0xfe, 0x62]));

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.binary);
      expect(doc.error, _binaryMessage);
    });

    test('invalid UTF-8 past the head is found too', () async {
      final path = at('c.dart');
      final bytes = Uint8List(9 * 1024)..fillRange(0, 9 * 1024, 0x61);
      bytes[8 * 1024 + 10] = 0xc3;
      bytes[8 * 1024 + 11] = 0x28;
      File(path).writeAsBytesSync(bytes);

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.binary);
      expect(doc.error, _binaryMessage);
    });

    test('a UTF-16 BOM is an encoding we do not decode, not a crash', () async {
      for (final bom in [
        [0xff, 0xfe],
        [0xfe, 0xff],
      ]) {
        final path = at('utf16_${bom.first}.txt');
        File(path).writeAsBytesSync(Uint8List.fromList([...bom, 0x61, 0x00]));

        final doc = await store.load(path);

        expect(doc.refusal, DocumentRefusal.binary, reason: '$bom');
        expect(doc.error, _binaryMessage);
      }
    });

    test('a UTF-8 BOM is text: stripped, remembered, written back', () async {
      final path = at('bom.dart');
      File(path).writeAsBytesSync(
        Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode('one\n')]),
      );

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.none);
      expect(doc.bom, isTrue);
      expect(doc.text, 'one\n');

      await store.write(path, doc.withText('one\ntwo\n').diskText);

      expect(File(path).readAsBytesSync(), [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('one\ntwo\n'),
      ]);
    });

    test('a file without a BOM does not grow one', () async {
      final path = at('plain.dart');
      File(path).writeAsStringSync('one\n');

      final doc = await store.load(path);
      expect(doc.bom, isFalse);

      await store.write(path, doc.withText('one\ntwo\n').diskText);

      expect(File(path).readAsBytesSync().first, 0x6f);
    });

    test('a path with nothing at it is not found', () async {
      final doc = await store.load(at('gone.dart'));

      expect(doc.refusal, DocumentRefusal.notFound);
      expect(doc.error, contains('gone.dart'));
      expect(doc.stamp, isNull);
    });

    test('a folder is unreadable, and says which it is', () async {
      final path = at('lib');
      Directory(path).createSync();

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.unreadable);
      expect(doc.error, contains('lib'));
      expect(doc.error, contains('folder'));
    });
  });

  group('how big it is decides how it opens', () {
    test('a file just under the editable limit opens to be edited', () async {
      final path = at('ok.dart');
      File(path).writeAsStringSync('a' * kEditableSizeLimit);

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.none);
      expect(doc.mode, DocumentMode.edit);
      expect(doc.isEditable, isTrue);
      expect(doc.text.length, kEditableSizeLimit);
    });

    test('a file just over it opens read-only, and whole', () async {
      final path = at('big.dart');
      File(path).writeAsStringSync('a' * (kEditableSizeLimit + 1));

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.none);
      expect(doc.isReadable, isTrue);
      expect(doc.mode, DocumentMode.view);
      expect(doc.isEditable, isFalse);
      expect(doc.error, isNull);
      expect(doc.text.length, kEditableSizeLimit + 1);
      expect(doc.canHighlight, isFalse);
    });

    test('a big file that is binary is still refused', () async {
      final path = at('big.bin');
      final bytes = Uint8List(kEditableSizeLimit + 1)
        ..fillRange(0, kEditableSizeLimit + 1, 0x61);
      bytes[3] = 0;
      File(path).writeAsBytesSync(bytes);

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.binary);
      expect(doc.text, isEmpty);
    });
  });

  group('line endings', () {
    test('a CRLF file is LF in the buffer and CRLF back on disk', () async {
      final path = at('crlf.dart');
      File(path).writeAsStringSync('one\r\ntwo\r\n');

      final doc = await store.load(path);
      expect(doc.crlf, isTrue);
      expect(doc.text, 'one\ntwo\n');

      final edited = doc.withText('one\ntwo\nthree\n');
      await store.write(path, edited.diskText);

      expect(File(path).readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
    });

    test('an LF file is not converted', () async {
      final path = at('lf.dart');
      File(path).writeAsStringSync('one\ntwo\n');

      final doc = await store.load(path);
      expect(doc.crlf, isFalse);

      await store.write(path, doc.withText('one\ntwo\nthree\n').diskText);

      expect(File(path).readAsStringSync(), 'one\ntwo\nthree\n');
      expect(File(path).readAsStringSync(), isNot(contains('\r')));
    });
  });

  group('stamping and writing', () {
    test('a stamp is null for nothing and follows what is written', () async {
      final path = at('a.dart');
      expect(await store.stamp(path), isNull);

      File(path).writeAsStringSync('one');
      final first = await store.stamp(path);
      expect(first, isNotNull);
      expect(first!.length, 3);

      final written = await store.write(path, 'one two');
      expect(written.length, 7);
      expect(written, await store.stamp(path));
      expect(first.matches(written), isFalse);
    });

    test('the stamp a write returns is the one on disk', () async {
      final path = at('a.dart');
      File(path).writeAsStringSync('one');

      final written = await store.write(path, 'much longer than before');

      expect(File(path).readAsStringSync(), 'much longer than before');
      expect(written.matches(await store.stamp(path)), isTrue);
    });

    test('a missing parent is refused rather than created', () async {
      final path = p.join(dir.path, 'nested', 'deep', 'a.dart');

      await expectLater(
        store.write(path, 'x'),
        throwsA(
          isA<DocumentWriteException>().having(
            (e) => e.message,
            'message',
            allOf(contains('a.dart'), contains('does not exist')),
          ),
        ),
      );
      expect(Directory(p.join(dir.path, 'nested')).existsSync(), isFalse);
    });

    test('writing over a folder fails with a reason, not a crash', () async {
      final path = at('lib');
      Directory(path).createSync();

      await expectLater(
        store.write(path, 'x'),
        throwsA(
          isA<DocumentWriteException>().having(
            (e) => e.message,
            'message',
            contains('lib'),
          ),
        ),
      );
    });
  });
}
