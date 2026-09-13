import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:path/path.dart' as p;

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
      File(path).writeAsBytesSync(
        Uint8List(3 * 1024 * 1024)..fillRange(0, 3 * 1024 * 1024, 0x61),
      );

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.tooLarge);
      expect(doc.isReadable, isFalse);
      expect(doc.text, isEmpty);
      expect(doc.error, contains('huge.dart'));
      expect(doc.error, contains('3.0 MB'));
      expect(doc.error, contains('2.0 MB'));
    });

    test('a NUL byte makes it binary', () async {
      final path = at('a.bin');
      File(path).writeAsBytesSync(Uint8List.fromList([0x61, 0x00, 0x62]));

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.binary);
      expect(doc.error, contains('a.bin'));
      expect(doc.error, contains('NUL'));
    });

    test('bytes that are not UTF-8 make it binary too', () async {
      final path = at('b.dart');
      File(path).writeAsBytesSync(Uint8List.fromList([0x61, 0xff, 0xfe, 0x62]));

      final doc = await store.load(path);

      expect(doc.refusal, DocumentRefusal.binary);
      expect(doc.error, contains('UTF-8'));
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
