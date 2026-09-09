import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/read.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// What a Codex store scan costs, counted in bytes read off the disk.
///
/// The scan re-decoded up to 400 lines of every rollout every time it ran.
/// Measured in a profile build with the window untouched, that was **39% of the
/// app's entire idle CPU** — the single largest thing it did while doing
/// nothing, ahead of every other caller combined.
///
/// It is pure waste, because everything the scan wants — `cwd`, the session id,
/// the start time, the first user message — is written at the *head* of the
/// rollout and never rewritten.
void main() {
  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_codex_cost');
    home = p.join(tmp.path, '.codex');
    Directory(p.join(home, 'sessions')).createSync(recursive: true);
  });

  tearDown(() => removeTempDirectory(tmp));

  File rollout(String id) =>
      File(p.join(home, 'sessions', 'rollout-$id.jsonl'));

  String line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

  /// A rollout with its meta at the head and enough bulk after it that
  /// re-reading is measurable.
  void write(String id, {int filler = 300, String cwd = '/repo'}) {
    rollout(id).writeAsStringSync([
      line({
        'type': 'session_meta',
        'timestamp': '2026-09-02T10:11:12.953Z',
        'payload': {'cwd': cwd, 'id': id, 'timestamp': '2026-09-02T10:11:12.953Z'},
      }),
      line({'type': 'message', 'role': 'user', 'content': 'the first thing said'}),
      for (var i = 0; i < filler; i++)
        line({'type': 'message', 'role': 'assistant', 'content': 'padding $i ' * 8}),
    ].join());
  }

  void append(String id, {int lines = 50}) {
    rollout(id).writeAsStringSync([
      for (var i = 0; i < lines; i++)
        line({'type': 'message', 'role': 'assistant', 'content': 'more $i'}),
    ].join(), mode: FileMode.append);
  }

  test('a second scan of an unchanged store reads nothing again', () async {
    write('s1');
    write('s2');
    final reader = CodexStoreReader(cache: CodexRolloutCache());

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

  test('a rollout that only grew is not read again either', () async {
    // The ordinary case for a live session, and the one that matters: a session
    // being written to is exactly the file a scan keeps meeting. Everything the
    // scan wants is at the head, so growth changes none of it.
    write('live');
    final reader = CodexStoreReader(cache: CodexRolloutCache());
    await reader.read(home, 'windows');
    final afterFirst = reader.bytesRead;

    append('live', lines: 200);
    final sessions = await reader.read(home, 'windows');

    expect(reader.bytesRead - afterFirst, 0);
    expect(sessions.single.cwd.path, '/repo', reason: 'and still correct');
  });

  test('a rollout replaced under the same name is read again', () async {
    // The one case the cache must not swallow. A shorter file is a different
    // file: its head can say something else entirely.
    write('s1', cwd: '/before', filler: 300);
    final reader = CodexStoreReader(cache: CodexRolloutCache());
    await reader.read(home, 'windows');
    final afterFirst = reader.bytesRead;

    write('s1', cwd: '/after', filler: 5);
    final sessions = await reader.read(home, 'windows');

    expect(reader.bytesRead, greaterThan(afterFirst), reason: 'it re-read');
    expect(sessions.single.cwd.path, '/after');
  });

  test('a rollout rewritten in place to the same length is read again', () async {
    // The hole a size-only cache left open. `/before` and `/aftera` are the
    // same number of bytes, so nothing but the mtime says the file moved — and
    // a rollout served from a stale cache is served stale for ever.
    write('s1', cwd: '/before');
    final reader = CodexStoreReader(cache: CodexRolloutCache());
    await reader.read(home, 'windows');
    final afterFirst = reader.bytesRead;
    final was = rollout('s1').lengthSync();

    write('s1', cwd: '/aftera');
    // Stamped rather than raced: two writes inside one clock tick would leave
    // the mtime unchanged and the case would prove nothing.
    rollout('s1').setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    final sessions = await reader.read(home, 'windows');

    expect(rollout('s1').lengthSync(), was, reason: 'the same size, exactly');
    expect(reader.bytesRead, greaterThan(afterFirst), reason: 'it re-read');
    expect(sessions.single.cwd.path, '/aftera');
  });

  test('the cost of a scan follows what changed, not the store size', () async {
    for (var i = 0; i < 20; i++) {
      write('s$i');
    }
    final reader = CodexStoreReader(cache: CodexRolloutCache());
    await reader.read(home, 'windows');
    final wholeStore = reader.bytesRead;

    // One file replaced out of twenty.
    write('s7', cwd: '/changed', filler: 5);
    final before = reader.bytesRead;
    await reader.read(home, 'windows');
    final secondScan = reader.bytesRead - before;

    expect(
      secondScan,
      lessThan(wholeStore ~/ 10),
      reason: 'one changed file out of twenty must not cost the whole store',
    );
  });
}
