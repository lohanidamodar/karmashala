import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

/// An archive somebody attaches to a bug report has to open on their machine,
/// and two exports of the same thing have to be the same file.
void main() {
  /// Reads the end-of-central-directory record back off [bytes].
  ({int entries, int size, int offset}) endRecord(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    // Fixed-size record with no comment, so it is the last 22 bytes.
    final at = bytes.length - 22;
    expect(view.getUint32(at, Endian.little), 0x06054b50);
    return (
      entries: view.getUint16(at + 10, Endian.little),
      size: view.getUint32(at + 12, Endian.little),
      offset: view.getUint32(at + 16, Endian.little),
    );
  }

  test('an empty archive is still a readable archive', () {
    final bytes = buildZipArchive([]);
    expect(bytes, hasLength(22));
    expect(endRecord(bytes).entries, 0);
  });

  test('every entry is signed, counted and pointed at', () {
    final bytes = buildZipArchive([
      ZipEntry.text('README.md', '# Hello'),
      ZipEntry.text('data/session.json', '{"a":1}'),
    ]);
    expect(bytes.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    final end = endRecord(bytes);
    expect(end.entries, 2);
    expect(end.offset + end.size + 22, bytes.length);
  });

  test('the same content twice is the same bytes', () {
    // Nothing in here may be stamped with the clock: an export diffed against
    // an earlier one should show what changed in the session, not the hour.
    List<int> once() => buildZipArchive([
      ZipEntry.text('a.md', 'the same text every time'),
      ZipEntry.text('b.json', '{"stable":true}'),
    ]);
    expect(once(), once());
  });

  test(
    'a path that tries to escape the archive is flattened, not resolved',
    () {
      final bytes = buildZipArchive([
        ZipEntry.text('../../etc/passwd', 'nope'),
        ZipEntry.text('/rooted.md', 'also nope'),
      ]);
      final text = latin1.decode(bytes);
      expect(text, contains('etc/passwd'));
      expect(text, isNot(contains('../')));
      expect(text, contains('rooted.md'));
      expect(endRecord(bytes).entries, 2);
    },
  );

  test('an entry whose name is nothing but escapes is dropped', () {
    expect(
      endRecord(buildZipArchive([ZipEntry.text('../..', 'x')])).entries,
      0,
    );
  });

  group('CRC-32', () {
    test('matches the published vector for "123456789"', () {
      expect(zipCrc32(utf8.encode('123456789')), 0xCBF43926);
    });

    test('is zero for nothing at all', () {
      expect(zipCrc32(const []), 0);
    });
  });

  test('text that compresses is deflated; text that does not is stored', () {
    // Both are legal; what matters is that the header says which was used and
    // the sizes agree with the bytes that follow.
    final compressible = buildZipArchive([ZipEntry.text('big.md', 'a' * 5000)]);
    final tiny = buildZipArchive([ZipEntry.text('t.md', 'x')]);
    expect(compressible.length, lessThan(2000));
    expect(ByteData.sublistView(compressible).getUint16(8, Endian.little), 8);
    expect(ByteData.sublistView(tiny).getUint16(8, Endian.little), 0);
  });

  group('written to disk', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('zip-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('lands at the path given, parents and all', () async {
      final path = '${dir.path}/nested/deeper/out.zip';
      await writeZipArchive(path, [ZipEntry.text('a.md', 'hi')]);
      final file = File(path);
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync().sublist(0, 2), [0x50, 0x4b]);
    });
  });
}
