import 'dart:io';

import 'package:agent_cli/read.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// **Deleting a selection of sessions at the server: one act.**
///
/// A bulk delete used to arrive as one `sessions.delete` or `imported.delete`
/// per row: N autocommits, and N change batches told to every other client,
/// each of which rebuilt that client's session list. `sessions.deleteMany`
/// takes the whole selection, applies it in one transaction and tells it as
/// one batch.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 10, 6, 12);

  void seedWorkspace() {
    const at = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Demo', 'windows', 'C:\\src\\p1', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'r1', 'windows', 'C:\\src\\r1', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claude-code', 'windows', 'claude', ?);",
      [at],
    );
  }

  void open(AppDatabase database) {
    db = database;
    service = DataService(db, clock: () => now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    seedWorkspace();
  }

  Session row(String id) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work $id',
    useWorktree: false,
    status: SessionStatus.completed,
    createdAt: now,
  );

  ImportedSession history(String id) => ImportedSession(
    id: id,
    repositoryId: 'r1',
    cli: 'claude-code',
    externalId: 'cli-$id',
    environmentId: 'windows',
    filePath: '$id.jsonl',
    storeHome: 'home',
    isSubagent: false,
    preview: id,
    createdAt: now,
  );

  /// [sessions] rows, each with [events] in its log, and [imported] records.
  void seed({required int sessions, int events = 0, int imported = 0}) {
    for (var i = 0; i < sessions; i++) {
      app.handle(SessionCreate(row('s$i')));
      if (events > 0) {
        app.handle(
          SessionEventsAppend([
            for (var e = 0; e < events; e++)
              SessionEvent(
                sessionId: 's$i',
                seq: e,
                type: 'message.agent',
                payload: '{"text":"turn $e of a long transcript"}',
                createdAt: now,
              ),
          ]),
        );
      }
    }
    for (var i = 0; i < imported; i++) {
      app.handle(ImportedAdd(history('i$i')));
    }
  }

  group('sessions.deleteMany', () {
    setUp(() => open(AppDatabase.memory()));
    tearDown(() => db.close());

    test('deletes the sessions and the imported records named, told as one '
        'batch', () {
      seed(sessions: 5, events: 3, imported: 4);
      told.clear();

      app.handle(
        const SessionsDeleteMany(
          sessionIds: ['s0', 's1', 's2'],
          importedIds: ['i0', 'i1'],
        ),
      );

      expect(told, hasLength(1), reason: 'one batch for the whole act');
      final changes = told.single.changes;
      expect(
        changes.whereType<SessionRowRemoved>().map((c) => c.id),
        ['s0', 's1', 's2'],
      );
      expect(
        changes.whereType<ImportedRemoved>().map((c) => c.id),
        ['i0', 'i1'],
      );
      final after = app.handle(const SessionsList()).value;
      expect(after.sessions.map((s) => s.id), unorderedEquals(['s3', 's4']));
      expect(after.imported.map((s) => s.id), unorderedEquals(['i2', 'i3']));
      expect(app.handle(const SessionEvents('s0')).value, isEmpty);
      expect(app.handle(const SessionEvents('s3')).value, hasLength(3));
    });

    test('an id already gone is skipped, not refused', () {
      seed(sessions: 2, imported: 1);
      app.handle(const SessionDelete('s0'));
      told.clear();

      app.handle(
        const SessionsDeleteMany(
          sessionIds: ['s0', 's1', 'never'],
          importedIds: ['i0', 'never'],
        ),
      );

      final after = app.handle(const SessionsList()).value;
      expect(after.sessions, isEmpty);
      expect(after.imported, isEmpty);
      expect(
        told.single.changes.whereType<SessionRowRemoved>().map((c) => c.id),
        ['s1'],
      );
    });

    test('nothing to delete tells nothing', () {
      seed(sessions: 1);
      told.clear();
      app.handle(const SessionsDeleteMany(sessionIds: ['never']));
      expect(told, isEmpty);
    });
  });

  group('the cost, on a store file', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('karmashala_delmany_');
      open(AppDatabase.open(tmp));
    });
    tearDown(() {
      db.close();
      tmp.deleteSync(recursive: true);
    });

    /// 120 sessions with 200 events each; 80 of them go.
    const sessions = 120;
    const going = 80;

    test('row by row against one request', () {
      seed(sessions: sessions, events: 200);
      told.clear();

      final perRow = Stopwatch()..start();
      for (var i = 0; i < going ~/ 2; i++) {
        app.handle(SessionDelete('s$i'));
      }
      perRow.stop();
      final perRowBatches = told.length;

      told.clear();
      final batched = Stopwatch()..start();
      app.handle(
        SessionsDeleteMany(
          sessionIds: [for (var i = going ~/ 2; i < going; i++) 's$i'],
        ),
      );
      batched.stop();

      // ignore: avoid_print
      print(
        'SERVER-DELETE-COST ${going ~/ 2} rows: row-by-row '
        '${perRow.elapsedMicroseconds}us in $perRowBatches batches; '
        'deleteMany ${batched.elapsedMicroseconds}us in ${told.length} batch',
      );
      expect(perRowBatches, going ~/ 2);
      expect(told, hasLength(1));
      expect(
        app.handle(const SessionsList()).value.sessions,
        hasLength(sessions - going),
      );
    });
  });
}
