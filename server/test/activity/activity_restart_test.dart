import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/activity/activity_log.dart';
import 'package:karmashala_host/src/activity/activity_writer.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A restart keeps the history: the log is the store's, on disk.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ks-activity-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('what was written before a restart is read after it', () async {
    final at = DateTime.utc(2026, 10, 6, 9);
    var db = AppDatabase.open(dir);
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('e1', 'windows', 'Desk', 't');",
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Alpha', 'e1', '/a', 't');",
    );
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      "created_at) VALUES ('r1', 'p1', 'a', 'e1', '/a', 't');",
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      "executable_path, created_at) VALUES ('a1', 'x', 'e1', '/x', 't');",
    );
    db.execute(
      'INSERT INTO sessions (id, repository_id, agent_installation_id, title, '
      "use_worktree, status, created_at) VALUES ('s1', 'r1', 'a1', 'T', 0, "
      "'running', ?);",
      [at.toIso8601String()],
    );
    final log = ActivityLog(db);
    final writer = ActivityWriter(
      append: log.append,
      tail: log.after,
      lastId: log.lastId,
      announce: (_) {},
      delay: const Duration(milliseconds: 1),
    );
    writer.record(
      ActivityDraft(
        at: at.add(const Duration(minutes: 5)),
        kind: ActivityKind.turnStarted,
        sessionId: 's1',
      ),
    );
    await writer.close();
    db.close();

    db = AppDatabase.open(dir);
    final page = ActivityLog(db).range(
      ActivityRange(from: at, to: at.add(const Duration(hours: 1))),
    );
    expect(page.entries.map((e) => (e.kind, e.title, e.projectName)), [
      (ActivityKind.sessionStarted, 'T', 'Alpha'),
      (ActivityKind.turnStarted, 'T', 'Alpha'),
    ]);
    db.close();
  });
}
