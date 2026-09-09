import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/cli_detection/data/claude_store_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// What a store scan costs, counted in bytes read off the disk.
///
/// The scan runs on the status registry's slow slot whenever a session row is
/// still waiting for its CLI's name — which a brand-new session always is. It
/// used to decode every line of every file each time: measured on the owner's
/// machine at **2.4 GB across 540 files**, one or two of which were being
/// written. That is what made switching sessions and starting one lag.
void main() {
  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_store_cost');
    home = p.join(tmp.path, '.claude');
    Directory(p.join(home, 'projects', '-repo')).createSync(recursive: true);
  });

  tearDown(() => removeTempDirectory(tmp));

  File sessionFile(String id) =>
      File(p.join(home, 'projects', '-repo', '$id.jsonl'));

  String line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

  /// A session with a title and enough bulk that re-reading it is measurable.
  void write(String id, {required String title, int filler = 400}) {
    sessionFile(id).writeAsStringSync([
      line({'type': 'user', 'cwd': '/repo', 'message': 'start'}),
      for (var i = 0; i < filler; i++)
        line({'type': 'assistant', 'message': 'padding line $i ' * 8}),
      line({'type': 'custom-title', 'customTitle': title}),
    ].join());
  }

  test('a second scan of an unchanged store reads nothing again', () async {
    write('s1', title: 'first');
    write('s2', title: 'second');
    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());

    final first = await reader.read(home, 'windows');
    expect(first, hasLength(2));
    expect(reader.bytesRead, greaterThan(0), reason: 'the first scan reads');
    final afterFirst = reader.bytesRead;

    await reader.read(home, 'windows');

    expect(
      reader.bytesRead - afterFirst,
      0,
      reason: 'nothing moved, so a stat is the whole of the second scan',
    );
  });

  test('a grown file is read from where the last scan stopped', () async {
    write('s1', title: 'before', filler: 400);
    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    await reader.read(home, 'windows');
    final sizeBefore = sessionFile('s1').lengthSync();

    sessionFile('s1').writeAsStringSync(
      line({'type': 'custom-title', 'customTitle': 'after'}),
      mode: FileMode.append,
    );
    final added = sessionFile('s1').lengthSync() - sizeBefore;
    final afterFirst = reader.bytesRead;

    await reader.read(home, 'windows');

    expect(
      reader.bytesRead - afterFirst,
      lessThanOrEqualTo(added),
      reason: 'only the appended record, not the whole $sizeBefore-byte file',
    );
  });

  test('and the new title is what the scan reports', () async {
    write('s1', title: 'before');
    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    expect((await reader.read(home, 'windows')).single.title, 'before');

    sessionFile('s1').writeAsStringSync(
      line({'type': 'custom-title', 'customTitle': 'after'}),
      mode: FileMode.append,
    );

    expect((await reader.read(home, 'windows')).single.title, 'after');
  });

  test('a record still being written is not resumed inside', () async {
    write('s1', title: 'before');
    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    await reader.read(home, 'windows');

    // A half-written line: no newline yet, which is what a live CLI leaves
    // between flushes.
    sessionFile('s1').writeAsStringSync(
      '{"type":"custom-tit',
      mode: FileMode.append,
    );
    expect((await reader.read(home, 'windows')).single.title, 'before');

    // Completed on the next flush, and now it counts.
    sessionFile('s1').writeAsStringSync(
      'le","customTitle":"after"}\n',
      mode: FileMode.append,
    );
    expect((await reader.read(home, 'windows')).single.title, 'after');
  });

  test('a file replaced wholesale is read again from the top', () async {
    write('s1', title: 'before', filler: 400);
    final reader = ClaudeStoreReader(cache: ClaudeStoreCache());
    await reader.read(home, 'windows');

    // Shorter than what was consumed — a rewritten or rotated store.
    sessionFile('s1').writeAsStringSync(
      [
        line({'type': 'user', 'cwd': '/repo', 'message': 'fresh'}),
        line({'type': 'custom-title', 'customTitle': 'rewritten'}),
      ].join(),
    );

    expect((await reader.read(home, 'windows')).single.title, 'rewritten');
  });
}
