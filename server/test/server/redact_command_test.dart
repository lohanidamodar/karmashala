import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:karmashala_host/src/backup/backup_manifest.dart';
import 'package:karmashala_host/src/backup/backup_writer.dart';
import 'package:karmashala_host/src/server/redact_command.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'server_test_support.dart';

// Made up, in the shapes real ones take.
const kFake = 'FAKE_TOKEN_123_not_real';
const kGrafana = 'glsa_FAKEgrafanaTOKENforTESTS01';

void main() {
  late Directory root;
  late String data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('karmashala-redact-test-');
    data = p.join(root.path, 'data');
    final db = AppDatabase.open(Directory(data)..createSync());
    db.execute('PRAGMA foreign_keys = OFF;');
    db.execute(
      'INSERT INTO conversation_turns (session_id, cli, ordinal, role, text) '
      "VALUES ('s1', 'grok', 0, 'agent', ?), ('s1', 'grok', 1, 'agent', ?);",
      ['servers {"env":{"ANY":"$kFake"}} and $kGrafana', 'nothing secret'],
    );
    db.execute(
      'INSERT INTO session_events (session_id, seq, type, payload, created_at) '
      "VALUES ('s1', 0, 'session.error', ?, '2026-10-12T00:00:00Z');",
      ['{"message":"exited","stderr":"API_TOKEN=$kFake"}'],
    );
    db.close();
    File(p.join(data, 'logs', 'server.log'))
      ..parent.createSync()
      ..writeAsStringSync(
        'INFO serve: started\n'
        'INFO acp: {"GRAFANA_API_KEY":"$kFake"}\n'
        'INFO acp: done\n',
      );
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(int, String)> run(List<String> args) async {
    final out = CapturingSink();
    final err = CapturingSink();
    final code = await runRedactSecrets(
      ['--data-dir=$data', ...args],
      out: out,
      err: err,
      environment: {'KARMASHALA_HOST_DIR': p.join(root.path, 'host')},
    );
    return (code, '${out.text}${err.text}');
  }

  String everything() {
    final db = sqlite3.open(p.join(data, kStoreFileName));
    try {
      return [
        for (final row in db.select('SELECT text FROM conversation_turns;'))
          row['text'],
        for (final row in db.select('SELECT payload FROM session_events;'))
          row['payload'],
        File(p.join(data, 'logs', 'server.log')).readAsStringSync(),
      ].join('\n');
    } finally {
      db.close();
    }
  }

  test(
    'without --apply it names places and counts, and changes nothing',
    () async {
      final (code, said) = await run([]);
      expect(code, 0);
      expect(said, contains('logs/server.log: 1 line(s)'));
      expect(said, contains('conversation_turns.text: 1 row(s)'));
      expect(said, contains('session_events.payload: 1 row(s)'));
      expect(said, contains('--apply'));
      expect(said, isNot(contains(kFake)));
      expect(everything(), contains(kFake));
    },
  );

  test('--apply masks them in place and keeps the rest', () async {
    final (code, said) = await run(['--apply']);
    expect(code, 0, reason: said);
    final after = everything();
    expect(after, isNot(contains(kFake)));
    expect(after, isNot(contains(kGrafana)));
    expect(after, contains('nothing secret'));
    expect(after, contains('INFO acp: done'));
    expect(after, contains('"message":"exited"'));

    final searched = sqlite3.open(p.join(data, kStoreFileName));
    addTearDown(searched.close);
    expect(
      searched.select(
        'SELECT rowid FROM conversation_turns_fts '
        "WHERE conversation_turns_fts MATCH 'FAKE_TOKEN_123_not_real';",
      ),
      isEmpty,
      reason: 'the search index forgets the old text too',
    );

    final (_, again) = await run([]);
    expect(again, contains('no secrets found'));
  });

  test('a backup carries the store with those rows masked', () async {
    final written = await writeBackup(
      dataDirectory: data,
      outputDirectory: p.join(root.path, 'backups'),
    );
    final entry = ZipDecoder()
        .decodeBytes(File(written.path).readAsBytesSync())
        .findFile(kSnapshotEntry)!;
    final copy = File(p.join(root.path, 'copy.sqlite'))
      ..writeAsBytesSync(entry.readBytes()!);
    final db = sqlite3.open(copy.path);
    addTearDown(db.close);
    final text = db
        .select('SELECT text FROM conversation_turns ORDER BY ordinal;')
        .map((row) => row['text'] as String)
        .join('\n');
    expect(text, isNot(contains(kFake)));
    expect(text, contains('nothing secret'));
    expect(
      db.select('SELECT payload FROM session_events;').single['payload'],
      isNot(contains(kFake)),
    );
    expect(
      everything(),
      contains(kFake),
      reason: 'the live store is untouched',
    );
  });

  test('a private key printed across lines is found and masked', () async {
    final log = File(p.join(data, 'logs', 'old.log'))
      ..writeAsStringSync(
        'INFO acp: before\n'
        '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'b3BlbnNzaC1rZXktdjEAAAAAFAKEkeyFORtestsONLY\n'
        'AAAAFAKEsecondLINEofTHEkeyNOTreal0123456789\n'
        '-----END OPENSSH PRIVATE KEY-----\n'
        'INFO acp: after\n',
      );
    final (_, found) = await run([]);
    expect(found, contains('logs/old.log: 4 line(s)'));

    final (code, said) = await run(['--apply']);
    expect(code, 0, reason: said);
    final after = log.readAsStringSync();
    expect(after, isNot(contains('FAKEkeyFORtests')));
    expect(after, isNot(contains('FAKEsecondLINE')));
    expect(after, contains('INFO acp: before\n'));
    expect(after, contains('INFO acp: after\n'));
  });

  // FTS5 keeps a term in its segment blocks after the row is masked, where
  // MATCH no longer finds it but the file's bytes still hold it. The index
  // lower-cases each term and shares a prefix with the term before it, so
  // the tail of the Grafana token's term is what lands in the bytes.
  const indexedTail = 'grafanatokenfortests01';
  bool holdsTerm(String path) {
    final bytes = [path, '$path-wal']
        .where((f) => File(f).existsSync())
        .expand((f) => File(f).readAsBytesSync());
    return latin1.decode(bytes.toList()).contains(indexedTail);
  }

  test('the indexed term really is in the store before masking', () {
    expect(holdsTerm(p.join(data, kStoreFileName)), isTrue);
  });

  test('--apply leaves no indexed term in the store file', () async {
    final (code, said) = await run(['--apply']);
    expect(code, 0, reason: said);
    expect(holdsTerm(p.join(data, kStoreFileName)), isFalse);
  });

  test('a backup leaves no indexed term in its snapshot file', () async {
    final written = await writeBackup(
      dataDirectory: data,
      outputDirectory: p.join(root.path, 'backups'),
    );
    final entry = ZipDecoder()
        .decodeBytes(File(written.path).readAsBytesSync())
        .findFile(kSnapshotEntry)!;
    final copy = File(p.join(root.path, 'copy.sqlite'))
      ..writeAsBytesSync(entry.readBytes()!);
    expect(holdsTerm(copy.path), isFalse);
  });
}
