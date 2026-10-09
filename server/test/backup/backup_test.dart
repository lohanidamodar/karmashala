import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:karmashala_host/src/backup/backup_manifest.dart';
import 'package:karmashala_host/src/backup/backup_restore.dart';
import 'package:karmashala_host/src/backup/backup_writer.dart';
import 'package:karmashala_host/src/backup/server_backups.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String data;
  late String out;

  setUp(() {
    root = Directory.systemTemp.createTempSync('karmashala-backup-test-');
    data = p.join(root.path, 'data');
    out = p.join(root.path, 'backups');
    Directory(data).createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String content) {
    File(p.join(data, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Archive unzip(String path) =>
      ZipDecoder().decodeBytes(File(path).readAsBytesSync());

  test('a snapshot taken while the server writes is consistent', () async {
    final db = AppDatabase.open(Directory(data));
    db.execute('CREATE TABLE ledger_a (n INTEGER PRIMARY KEY, pad TEXT);');
    db.execute('CREATE TABLE ledger_b (n INTEGER PRIMARY KEY, pad TEXT);');
    final pad = 'x' * 2000;
    var writes = 0;
    var writing = true;
    var duringBackup = 0;
    // Each write puts one row in each ledger in one transaction, so a torn
    // copy would show different counts.
    Future<void> writer() async {
      while (writing) {
        db.execute('BEGIN;');
        db.execute('INSERT INTO ledger_a (pad) VALUES (?);', [pad]);
        db.execute('INSERT INTO ledger_b (pad) VALUES (?);', [pad]);
        db.execute('COMMIT;');
        writes++;
        await Future<void>.delayed(Duration.zero);
      }
    }

    for (var i = 0; i < 2000; i++) {
      db.execute('INSERT INTO ledger_a (pad) VALUES (?);', [pad]);
      db.execute('INSERT INTO ledger_b (pad) VALUES (?);', [pad]);
    }
    final running = writer();
    final before = writes;
    final written = await writeBackup(
      dataDirectory: data,
      outputDirectory: out,
    );
    duringBackup = writes - before;
    writing = false;
    await running;
    db.close();

    expect(duringBackup, greaterThan(0), reason: 'no write overlapped');
    final snapshot = p.join(root.path, 'snapshot.sqlite');
    final entry = unzip(written.path).findFile(kSnapshotEntry)!;
    File(snapshot).writeAsBytesSync(entry.readBytes()!);
    final copy = sqlite3.open(snapshot);
    addTearDown(copy.close);
    expect(copy.select('PRAGMA integrity_check;').first.values.first, 'ok');
    final a = copy.select('SELECT COUNT(*) AS n FROM ledger_a;').first['n'];
    final b = copy.select('SELECT COUNT(*) AS n FROM ledger_b;').first['n'];
    expect(a, b);
    expect(a, greaterThanOrEqualTo(2000));
    expect(written.manifest.counts['ledger_a'], a);
  });

  test(
    'the manifest names the version, schema, counts, files and refs',
    () async {
      final db = AppDatabase.open(Directory(data));
      db.execute(
        'INSERT INTO session_checkpoints (id, session_id, environment_id, '
        'repository_path, sequence, tree_sha, commit_sha, reason, created_at) '
        "VALUES ('c1', 's1', 'local', '/repo', 1, 't1', 'aaa', 'turn', 'x'), "
        "('c2', 's1', 'local', '/repo', 2, 't2', 'bbb', 'turn', 'x');",
      );
      final schema = db.schemaVersion;
      db.close();
      write('artifacts/report.html', '<p>hi</p>');
      write('artifacts/visuals/v1.json', '{}');
      write('verification/run1/shot.png', 'png');
      write('uploads/a.txt', 'a');
      write('artifacts/.env.local', 'TOKEN=1');

      final written = await writeBackup(
        dataDirectory: data,
        outputDirectory: out,
        now: DateTime.utc(2026, 10, 9, 15, 30, 12),
      );
      expect(p.basename(written.path), 'karmashala-backup-20261009-153012.zip');
      final manifest = BackupManifest.decode(
        unzip(written.path).findFile(kManifestEntry)!.readBytes()!,
      );
      expect(manifest.appVersion, kHostVersion);
      expect(manifest.schemaVersion, schema);
      expect(manifest.createdAt, DateTime.utc(2026, 10, 9, 15, 30, 12));
      expect(manifest.counts['session_checkpoints'], 2);
      expect(manifest.files.map((f) => f.path), [
        'artifacts/report.html',
        'artifacts/visuals/v1.json',
        'uploads/a.txt',
        'verification/run1/shot.png',
      ]);
      expect(manifest.skipped, ['artifacts/.env.local']);
      // SHA-256 of "a".
      expect(
        manifest.files[2].sha256,
        'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb',
      );
      expect(manifest.checkpoints.single.toJson(), {
        'environmentId': 'local',
        'repositoryPath': '/repo',
        'ref': 'refs/karmashala/checkpoints/s1',
        'commitSha': 'bbb',
        'checkpoints': 2,
      });
      expect(manifest.excluded, kBackupExclusions);
      expect(manifest.notCarried, kBackupNotCarried);
    },
  );

  test('credentials never reach the archive', () async {
    const vault = 'FAKE-VAULT-SECRET-7f3a';
    const pairing = 'FAKE-PAIRING-KEY-91bc';
    const env = 'FAKE-ENV-FILE-SECRET-22';
    final db = AppDatabase.open(Directory(data));
    db.execute(
      'INSERT INTO paired_devices (id, name, device_key, capabilities, '
      "generation, push_token, created_at) VALUES ('d1', 'Phone', ?, 1, 1, "
      "?, 'x');",
      [pairing, pairing],
    );
    db.close();
    write('secrets/stores.json', '{"key": "$vault"}');
    write('secrets/env.json', '{"KEY": "$vault"}');
    write('secrets/github.json', '{"token": "$vault"}');
    write('server.json', '{"companion": {"relayToken": "$vault"}}');
    write('mcp_bridge.json', '{"token": "$vault"}');
    write('mcp/session-1.json', '{"token": "$vault"}');
    write('attachments/.env', 'KEY=$env');
    write('attachments/key.properties', 'storePassword=$env');
    write('artifacts/release.jks', env);
    write('attachments/photo.txt', 'fine');

    final written = await writeBackup(
      dataDirectory: data,
      outputDirectory: out,
    );
    final zip = unzip(written.path);
    for (final entry in zip.files.where((e) => e.isFile)) {
      final text = latin1.decode(entry.readBytes()!);
      for (final secret in [vault, pairing, env]) {
        expect(text, isNot(contains(secret)), reason: entry.name);
      }
    }
    expect(zip.files.map((e) => e.name), [
      kManifestEntry,
      kSnapshotEntry,
      'files/attachments/photo.txt',
    ]);
    expect(written.manifest.counts['paired_devices'], 0);
    expect(
      written.manifest.skipped,
      containsAll([
        'attachments/.env',
        'attachments/key.properties',
        'artifacts/release.jks',
      ]),
    );
  });

  test('a backup is refused inside the data folder', () async {
    AppDatabase.open(Directory(data)).close();
    await expectLater(
      writeBackup(dataDirectory: data, outputDirectory: p.join(data, 'b')),
      throwsA(isA<BackupRefused>()),
    );
  });

  group('restore', () {
    /// A store at schema [version], built by the migrations up to it, as an
    /// older Karmashala left it.
    void oldStore(String directory, int version) {
      Directory(directory).createSync(recursive: true);
      final db = sqlite3.open(p.join(directory, kStoreFileName));
      final steps = schemaMigrations.keys.where((v) => v <= version).toList()
        ..sort();
      for (final step in steps) {
        schemaMigrations[step]!(db);
      }
      db.execute('PRAGMA user_version = $version;');
      db.execute(
        "INSERT INTO app_metadata (key, value, updated_at) VALUES ('settings.v1', "
        "'{\"restored\": true}', 'x');",
      );
      db.close();
    }

    test('an older backup restores into a fresh folder, migrated', () async {
      final old = p.join(root.path, 'old');
      oldStore(old, 80);
      File(p.join(old, 'artifacts', 'kept.html'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('from the backup');
      final written = await writeBackup(
        dataDirectory: old,
        outputDirectory: out,
      );
      expect(written.manifest.schemaVersion, 80);

      final current = AppDatabase.open(Directory(data));
      final head = current.schemaVersion;
      current.writeMetadata('settings.v1', '{"restored": false}');
      current.execute(
        'INSERT INTO paired_devices (id, name, device_key, capabilities, '
        "generation, created_at) VALUES ('d1', 'Phone', 'k', 1, 1, 'x');",
      );
      current.close();
      write('artifacts/replaced.html', 'old');
      write('secrets/stores.json', '{"stays": true}');

      final inspected = await inspectBackup(written.path, knownSchema: head);
      expect(inspected.refusal, isNull);
      expect(inspected.manifest.files.single.path, 'artifacts/kept.html');

      final staged = await stageRestore(
        written.path,
        dataDirectory: data,
        now: DateTime.utc(2026, 10, 9, 12),
      );
      expect(staged.schemaFrom, 80);
      expect(staged.schemaTo, head);
      expect(p.dirname(staged.staged), root.path);
      expect(pendingRestore(data), isNotNull);
      // Staging leaves the live folder as it was.
      expect(
        File(p.join(data, 'artifacts', 'replaced.html')).existsSync(),
        isTrue,
      );

      final line = applyPendingRestore(
        data,
        now: DateTime.utc(2026, 10, 9, 12, 5),
      );
      expect(line, contains('restored'));
      final before = p.join(root.path, 'data.before-restore-20261009-120500');
      expect(File(p.join(before, kStoreFileName)).existsSync(), isTrue);
      expect(
        File(p.join(before, 'artifacts', 'replaced.html')).existsSync(),
        isTrue,
      );
      expect(Directory(staged.staged).existsSync(), isFalse);
      expect(pendingRestore(data), isNull);
      expect(
        File(p.join(data, 'artifacts', 'kept.html')).readAsStringSync(),
        'from the backup',
      );
      expect(
        File(p.join(data, 'artifacts', 'replaced.html')).existsSync(),
        isFalse,
      );
      expect(File(p.join(data, 'secrets', 'stores.json')).existsSync(), isTrue);

      final restored = AppDatabase.open(
        Directory(data),
        refuseNewerSchema: true,
      );
      addTearDown(restored.close);
      expect(restored.readMetadata('settings.v1'), '{"restored": true}');
      expect(restored.query('PRAGMA user_version;').first.values.first, head);
      expect(
        restored.query('SELECT id FROM paired_devices;').single['id'],
        'd1',
      );
      final last = lastRestore(data)!;
      expect(last['before'], before);
      expect(last['phonesKept'], 1);
    });

    test(
      'a backup from a newer schema is refused, and nothing is staged',
      () async {
        final db = AppDatabase.open(Directory(data));
        final head = db.schemaVersion;
        db.execute('PRAGMA user_version = ${head + 1};');
        db.close();
        final written = await writeBackup(
          dataDirectory: data,
          outputDirectory: out,
        );

        final inspected = await inspectBackup(written.path, knownSchema: head);
        expect(inspected.refusal, contains('newer Karmashala'));
        expect(inspected.refusal, contains('Update Karmashala'));
        await expectLater(
          stageRestore(written.path, dataDirectory: data),
          throwsA(
            isA<BackupRefused>().having(
              (e) => e.message,
              'message',
              contains('schema v${head + 1}'),
            ),
          ),
        );
        expect(
          root.listSync().map((e) => p.basename(e.path)),
          isNot(contains(startsWith('data.restore-'))),
        );
        expect(pendingRestore(data), isNull);
      },
    );

    test('a file that does not match the manifest is refused', () async {
      AppDatabase.open(Directory(data)).close();
      write('uploads/a.txt', 'original');
      final written = await writeBackup(
        dataDirectory: data,
        outputDirectory: out,
      );
      final zip = unzip(written.path);
      final tampered = Archive();
      for (final entry in zip.files) {
        tampered.addFile(
          entry.name == 'files/uploads/a.txt'
              ? ArchiveFile.string(entry.name, 'changed!')
              : ArchiveFile.bytes(entry.name, entry.readBytes()!),
        );
      }
      final path = p.join(out, 'tampered.zip');
      File(path).writeAsBytesSync(ZipEncoder().encode(tampered));
      await expectLater(
        stageRestore(path, dataDirectory: data),
        throwsA(isA<BackupRefused>()),
      );
      expect(pendingRestore(data), isNull);
    });

    test('a file that is not a backup is refused', () async {
      final path = p.join(root.path, 'not.zip');
      File(path).writeAsStringSync('hello');
      await expectLater(
        inspectBackup(path, knownSchema: 1),
        throwsA(isA<BackupRefused>()),
      );
    });
  });

  group('schedule', () {
    test('backs up when due and keeps the newest N', () async {
      final db = AppDatabase.open(Directory(data));
      addTearDown(db.close);
      var now = DateTime.utc(2026, 10, 1, 9);
      final backups = ServerBackups(
        dataDirectory: data,
        database: db,
        clock: () => now,
      );
      expect(await backups.runScheduled(), isNull, reason: 'off by default');

      Directory(out).createSync();
      File(p.join(out, 'notes.txt')).writeAsStringSync('mine');
      db.writeMetadata(
        BackupSchedule.key,
        jsonEncode({'frequency': 'daily', 'keep': 2, 'folder': out}),
      );
      expect(await backups.runScheduled(), isNotNull);
      now = now.add(const Duration(hours: 5));
      expect(await backups.runScheduled(), isNull, reason: 'not yet due');
      for (var day = 0; day < 3; day++) {
        now = now.add(const Duration(days: 1));
        expect(await backups.runScheduled(), isNotNull);
      }
      final names = Directory(
        out,
      ).listSync().map((e) => p.basename(e.path)).toList()..sort();
      expect(names, [
        'karmashala-backup-20261003-140000.zip',
        'karmashala-backup-20261004-140000.zip',
        'notes.txt',
      ]);
      expect(backups.describe(), containsPair('frequency', 'daily'));
      expect(backups.describe()['newest'], '2026-10-04T14:00:00.000Z');
    });

    test('weekly waits a week', () async {
      final db = AppDatabase.open(Directory(data));
      addTearDown(db.close);
      var now = DateTime.utc(2026, 10, 1);
      final backups = ServerBackups(
        dataDirectory: data,
        database: db,
        clock: () => now,
      );
      db.writeMetadata(
        BackupSchedule.key,
        jsonEncode({'frequency': 'weekly', 'keep': 3, 'folder': out}),
      );
      expect(await backups.runScheduled(), isNotNull);
      now = now.add(const Duration(days: 6));
      expect(await backups.runScheduled(), isNull);
      now = now.add(const Duration(days: 1));
      expect(await backups.runScheduled(), isNotNull);
    });

    test('the schedule is read with defaults and limits', () {
      expect(BackupSchedule.fromJson(null).frequency, BackupFrequency.off);
      final schedule = BackupSchedule.fromJson({
        'frequency': 'hourly',
        'keep': 1000,
        'folder': '  ',
      });
      expect(schedule.frequency, BackupFrequency.off);
      expect(schedule.keep, BackupSchedule.maxKeep);
      expect(schedule.folder, isNull);
    });
  });

  test('backup names round-trip their time', () {
    final at = DateTime.utc(2026, 1, 2, 3, 4, 5);
    expect(backupFileTime(backupFileName(at)), at);
    expect(backupFileTime('karmashala-backup-x.zip'), isNull);
  });
}
