import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/util/bounded_lines.dart';
import 'package:test/test.dart';

/// The splitter has to match `LineSplitter` in every respect a transcript
/// depends on, and differ in exactly one: it never builds a record over the
/// bound.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('karmashala_lines'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can still hold the handle; the temp directory is disposable.
    }
  });

  File write(String name, String content) =>
      File('${dir.path}/$name')..writeAsBytesSync(utf8.encode(content));

  Future<List<String>> lines(File file, {int? maxBytes}) => boundedLines(
    file,
    maxBytes: maxBytes ?? kMaxTranscriptLineBytes,
  ).toList();

  test(
    'splits on \\n and \\r\\n, and drops neither the first nor the last',
    () async {
      expect(await lines(write('a.jsonl', 'one\ntwo\r\nthree')), [
        'one',
        'two',
        'three',
      ]);
    },
  );

  test('a trailing newline does not produce an empty last record', () async {
    expect(await lines(write('b.jsonl', 'one\ntwo\n')), ['one', 'two']);
  });

  test('an empty record between two full ones is preserved', () async {
    expect(await lines(write('c.jsonl', 'one\n\ntwo\n')), ['one', '', 'two']);
  });

  test('a multi-byte code point split across read chunks survives', () async {
    // 100 KiB either side, so the emoji lands well past `openRead`'s first
    // chunk. A per-line decode that ignored the chunking would emit
    // replacement characters here.
    final filler = 'a' * (100 * 1024);
    final got = await lines(write('d.jsonl', '$filler😀$filler\n'));
    expect(got, hasLength(1));
    expect(got.single.contains('😀'), isTrue);
    expect(got.single.length, filler.length * 2 + 2);
  });

  test(
    'a record over the bound is never built, and its neighbours survive',
    () async {
      expect(
        await lines(
          write('e.jsonl', 'before\n${'x' * 4096}\nafter\n'),
          maxBytes: 1024,
        ),
        ['before', 'after'],
        reason:
            'the oversized record is refused, not truncated into a '
            'half-record the parser would then misread',
      );
    },
  );

  test('an oversized record at the end of the file is refused too', () async {
    expect(
      await lines(write('f.jsonl', 'before\n${'x' * 4096}'), maxBytes: 1024),
      ['before'],
    );
  });

  test('a record exactly at the bound is kept', () async {
    expect(
      await lines(write('g.jsonl', '${'x' * 1024}\nafter\n'), maxBytes: 1024),
      ['x' * 1024, 'after'],
    );
  });

  test('two oversized records in a row drop only themselves', () async {
    final big = 'x' * 4096;
    expect(
      await lines(write('h.jsonl', 'a\n$big\n$big\nb\n'), maxBytes: 1024),
      ['a', 'b'],
    );
  });

  test('a file that is one oversized record yields nothing', () async {
    expect(await lines(write('i.jsonl', 'x' * 8192), maxBytes: 1024), isEmpty);
  });
}
