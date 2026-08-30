import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/util/clock.dart';
import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/imported_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/notifications/application/watched_session_loader.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A clock the test moves forward, for the cold-recheck window.
class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

void main() {
  late AppDatabase db;
  late Directory temp;
  late SessionDao sessions;
  late ImportedSessionDao imported;
  late AgentInstallationDao installations;
  late AgentHookReports reports;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    temp = Directory.systemTemp.createTempSync('watched-sessions');
    sessions = SessionDao(db);
    imported = ImportedSessionDao(db);
    installations = AgentInstallationDao(db);
    reports = AgentHookReports();
    installations.insert(agentInstallation());
    addTearDown(() {
      db.close();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  WatchedSessionLoader loader({int limit = 60}) => WatchedSessionLoader(
    sessionDao: sessions,
    importedSessionDao: imported,
    installationDao: installations,
    hookReports: reports,
    clock: FixedClock(testTime),
    limit: limit,
  );

  /// Writes a transcript file whose last-modified time is [age] before now.
  String transcript(String name, {Duration age = Duration.zero}) {
    final path = p.join(temp.path, '$name.jsonl');
    final file = File(path)..writeAsStringSync('{}\n');
    file.setLastModifiedSync(testTime.subtract(age));
    return path;
  }

  void addImported(
    String id, {
    required String externalId,
    required String filePath,
    String title = 'Imported',
  }) => imported.insertIfAbsent(
    ImportedSession(
      id: id,
      repositoryId: 'r1',
      cli: AgentIds.claudeCode,
      externalId: externalId,
      environmentId: 'windows',
      filePath: filePath,
      storeHome: temp.path,
      isSubagent: false,
      preview: 'hello',
      title: title,
      createdAt: testTime,
    ),
  );

  test('a transcript that changed recently is watched', () {
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: transcript('a', age: const Duration(minutes: 2)),
    );

    final watched = loader().load();

    expect(watched, hasLength(1));
    expect(watched.single.key.sessionId, 'cli-1');
    expect(watched.single.label, 'Imported');
    expect(watched.single.imported, isTrue);
    expect(watched.single.openId, 'i1');
  });

  test('a cold transcript is history, not something to watch', () {
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: transcript('a', age: const Duration(hours: 6)),
    );

    expect(loader().load(), isEmpty);
  });

  test('a cold transcript a hook has spoken about is watched anyway', () {
    // The agent told us about it, so the file's age says nothing useful.
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: transcript('a', age: const Duration(hours: 6)),
    );
    reports.record(
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-1',
        status: AgentActivityStatus.awaitingApproval,
        source: AgentStatusSource.hook,
        observedAt: testTime,
      ),
    );

    expect(loader().load(), hasLength(1));
  });

  test('a missing transcript file is skipped', () {
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: p.join(temp.path, 'gone.jsonl'),
    );

    expect(loader().load(), isEmpty);
  });

  test('a native session with a CLI id is watched', () {
    sessions.insert(session(id: 's1').copyWith(externalSessionId: 'cli-9'));

    final watched = loader().load();

    expect(watched, hasLength(1));
    expect(watched.single.key.agentId, AgentIds.claudeCode);
    expect(watched.single.key.sessionId, 'cli-9');
    expect(watched.single.imported, isFalse);
    expect(watched.single.stateFilePath, isNull);
  });

  test('a native session the CLI has not named yet is skipped', () {
    sessions.insert(session(id: 's1'));

    expect(loader().load(), isEmpty);
  });

  test('a finished native session can no longer produce status', () {
    for (final status in [
      SessionStatus.completed,
      SessionStatus.cancelled,
      SessionStatus.failed,
    ]) {
      sessions.insert(
        session(
          id: 's-${status.name}',
          status: status,
        ).copyWith(externalSessionId: 'cli-${status.name}'),
      );
    }

    expect(loader().load(), isEmpty);
  });

  test('a cold transcript is left alone until the recheck window passes', () {
    // The saving that keeps a 5-second poll off a workspace with hundreds of
    // archived sessions; the cost is this much latency waking one back up.
    final clock = _MovableClock(testTime);
    final loader = WatchedSessionLoader(
      sessionDao: sessions,
      importedSessionDao: imported,
      installationDao: installations,
      hookReports: reports,
      clock: clock,
      coldRecheck: const Duration(minutes: 1),
    );
    final path = transcript('a', age: const Duration(hours: 6));
    addImported('i1', externalId: 'cli-1', filePath: path);

    expect(loader.load(), isEmpty);

    // The agent wakes up and writes, but we are inside the recheck window.
    File(path).setLastModifiedSync(clock.now);
    expect(loader.load(), isEmpty);

    clock.now = testTime.add(const Duration(minutes: 2));
    File(path).setLastModifiedSync(clock.now);
    expect(loader.load(), hasLength(1));
  });

  test('the newest sessions win when the cap bites', () {
    for (var i = 0; i < 5; i++) {
      addImported(
        'i$i',
        externalId: 'cli-$i',
        filePath: transcript('t$i', age: Duration(minutes: i)),
        title: 'Session $i',
      );
    }

    final watched = loader(limit: 2).load();

    expect(watched.map((s) => s.key.sessionId), ['cli-0', 'cli-1']);
  });
}
