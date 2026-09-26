import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/watched_session_loader.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

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
    FakeDataServer().mirrorInto(db)
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
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

  /// Pane ids a test says are running in this app instance.
  final livePanes = <String>{};
  setUp(livePanes.clear);

  WatchedSessionLoader loader({
    Clock? clock,
    String? Function(String sessionId)? transcriptPathFor,
  }) => WatchedSessionLoader(
    sessionDao: sessions,
    importedSessionDao: imported,
    installationDao: installations,
    hookReports: reports,
    clock: clock ?? FixedClock(testTime),
    isPaneLive: livePanes.contains,
    transcriptPathFor: transcriptPathFor,
  );

  void hook(String sessionId) => reports.record(
    AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: sessionId,
      status: AgentActivityStatus.working,
      source: AgentStatusSource.hook,
      observedAt: testTime,
    ),
  );

  /// The workspace, once the sampler has read the transcripts.
  ///
  /// `load()` reports the last *sample* of a transcript's timestamp rather than
  /// stat-ing it, so the first call over a path it has not seen starts the read
  /// and the second reports it. Production never waits: the next status cycle
  /// is 1.2 seconds away and reads whatever finished in the meantime.
  Future<List<WatchedSession>> settled(WatchedSessionLoader subject) async {
    subject.load();
    await subject.settle();
    return subject.load();
  }

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

  test('reading the workspace never stats a transcript synchronously', () async {
    // The periodic hitch of Loop 90. `load()` runs on the UI isolate every 1.2
    // seconds, and it used to `existsSync()` + `lastModifiedSync()` every
    // imported transcript that was due a recheck. On the owner's machine 64 of
    // those files live under `\\wsl.localhost\...`, where the pair measured
    // 1.19 ms against 0.07 ms on local NTFS — 67 ms of blocked UI thread for
    // one sweep, once a minute.
    for (var i = 0; i < 60; i++) {
      addImported(
        'i$i',
        externalId: 'cli-$i',
        filePath: transcript('t$i', age: const Duration(minutes: 1)),
      );
    }
    final tally = _Tally();
    final subject = loader();

    await IOOverrides.runZoned(() async {
      subject.load();
      await subject.settle();
      subject.load();
    }, createFile: (path) => _CountingFile(path, tally));

    expect(tally.sync, 0, reason: 'a synchronous stat is a blocked frame');
    expect(tally.async, greaterThanOrEqualTo(60));
  });

  test(
    'the cold recheck is spread across its window, not paid in one cycle',
    () async {
      // The other half of the hitch. Every cold transcript used to be found cold
      // in the same cycle and given the same deadline, so a minute later they all
      // came due at once: fifty-nine free ticks and then one that swept the whole
      // workspace. Spreading the deadlines turns that burst into a hum.
      const count = 100;
      for (var i = 0; i < count; i++) {
        addImported(
          'i$i',
          externalId: 'cli-$i',
          filePath: transcript('t$i', age: const Duration(hours: 6)),
        );
      }
      final clock = _MovableClock(testTime);
      final subject = WatchedSessionLoader(
        sessionDao: sessions,
        importedSessionDao: imported,
        installationDao: installations,
        hookReports: reports,
        clock: clock,
        coldRecheck: const Duration(minutes: 1),
      );
      await settled(subject);

      // Two recheck windows at the real status-cycle rate.
      var worst = 0;
      for (var i = 0; i < 100; i++) {
        clock.now = clock.now.add(const Duration(milliseconds: 1200));
        final tally = _Tally();
        await IOOverrides.runZoned(() async {
          subject.load();
          await subject.settle();
        }, createFile: (path) => _CountingFile(path, tally));
        if (tally.async > worst) worst = tally.async;
      }

      expect(
        worst,
        lessThan(count ~/ 4),
        reason: 'no single cycle may re-read a quarter of the workspace',
      );
    },
  );

  test('a transcript that changed recently is watched', () async {
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: transcript('a', age: const Duration(minutes: 2)),
    );

    final watched = await settled(loader());

    expect(watched, hasLength(1));
    expect(watched.single.key.sessionId, 'cli-1');
    expect(watched.single.label, 'Imported');
    expect(watched.single.imported, isTrue);
    expect(watched.single.openId, 'i1');
  });

  test('a cold transcript is history, not something to watch', () async {
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: transcript('a', age: const Duration(hours: 6)),
    );

    expect(await settled(loader()), isEmpty);
  });

  test('a cold transcript a hook has spoken about is watched anyway', () async {
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

    expect(await settled(loader()), hasLength(1));
  });

  test('a missing transcript file is skipped', () async {
    addImported(
      'i1',
      externalId: 'cli-1',
      filePath: p.join(temp.path, 'gone.jsonl'),
    );

    expect(await settled(loader()), isEmpty);
  });

  test('a native session with a CLI id in a live pane is watched', () async {
    sessions.insert(
      session(id: 's1').copyWith(externalSessionId: 'cli-9', paneId: 'pane-9'),
    );
    livePanes.add('pane-9');

    final watched = await settled(loader());

    expect(watched, hasLength(1));
    expect(watched.single.key.agentId, AgentIds.claudeCode);
    expect(watched.single.key.sessionId, 'cli-9');
    expect(watched.single.imported, isFalse);
    expect(
      watched.single.paneId,
      'pane-9',
      reason: 'the status cycle must not query this row again for its pane',
    );
    expect(watched.single.stateFilePath, isNull);
  });

  test('a native session the CLI has not named yet is watched anyway', () async {
    // Rewritten in Loop 87. It used to assert this session was skipped, on the
    // reasoning that a status can only come from a hook and a hook is keyed by
    // the CLI's own id. That stopped being true when the terminal grid became a
    // source: the session has a screen, the screen says whether it is waiting on
    // the user, and the visible badge has been reading it all along — keyed by
    // the row id, exactly as here. Skipping it was how the ambient pipeline
    // ended up reporting `unknown` for a session the badge beside it could read.
    sessions.insert(session(id: 's1').copyWith(paneId: 'pane-1'));
    livePanes.add('pane-1');

    final watched = await settled(loader());

    expect(watched, hasLength(1));
    expect(watched.single.key.sessionId, 's1', reason: 'keyed by our own id');
    expect(watched.single.openId, 's1');
    expect(watched.single.stateFilePath, isNull);
  });

  test('a finished native session can no longer produce status', () async {
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

    expect(await settled(loader()), isEmpty);
  });

  test('an ended row observed running again is watched', () async {
    // A host restart can leave a row `completed` while its pane has started
    // the conversation again; what runs, not what was recorded, decides.
    sessions
      ..insert(
        session(
          id: 'hosted',
          status: SessionStatus.completed,
        ).copyWith(externalSessionId: 'cli-hosted'),
      )
      ..insert(
        session(
          id: 'paned',
          status: SessionStatus.failed,
        ).copyWith(externalSessionId: 'cli-paned', paneId: 'pane-1'),
      )
      ..insert(
        session(
          id: 'over',
          status: SessionStatus.completed,
        ).copyWith(externalSessionId: 'cli-over'),
      );
    livePanes.add('pane-1');
    final subject = WatchedSessionLoader(
      sessionDao: sessions,
      importedSessionDao: imported,
      installationDao: installations,
      hookReports: reports,
      clock: FixedClock(testTime),
      isPaneLive: livePanes.contains,
      isRunningOnHost: (id) => id == 'hosted',
    );

    final watched = await settled(subject);
    expect(watched.map((w) => w.openId), unorderedEquals(['hosted', 'paned']));
  });

  test(
    'a cold transcript is left alone until the recheck window passes',
    () async {
      // The saving that keeps a 5-second poll off a workspace with hundreds of
      // archived sessions; the cost is this much latency waking one back up.
      final clock = _MovableClock(testTime);
      final subject = WatchedSessionLoader(
        sessionDao: sessions,
        importedSessionDao: imported,
        installationDao: installations,
        hookReports: reports,
        clock: clock,
        coldRecheck: const Duration(minutes: 1),
      );
      final path = transcript('a', age: const Duration(hours: 6));
      addImported('i1', externalId: 'cli-1', filePath: path);

      expect(await settled(subject), isEmpty);

      // The agent wakes up and writes, but we are inside the recheck window.
      File(path).setLastModifiedSync(clock.now);
      expect(await settled(subject), isEmpty);

      // Two windows on, past the longest offset the jitter can add.
      clock.now = testTime.add(const Duration(minutes: 2));
      File(path).setLastModifiedSync(clock.now);
      expect(await settled(subject), hasLength(1));
    },
  );

  test('live sessions come back newest first', () async {
    // Rewritten in Loop 87. It used to pass `limit: 2` and assert that the two
    // newest sessions were the only ones returned — the 60-session cap that
    // made session 61 invisible to notifications forever. Recency is still the
    // order, because it decides which waiting session the tray names first; it
    // is no longer a selection.
    for (var i = 0; i < 5; i++) {
      addImported(
        'i$i',
        externalId: 'cli-$i',
        filePath: transcript('t$i', age: Duration(minutes: i)),
        title: 'Session $i',
      );
    }

    final watched = await settled(loader());

    expect(watched.map((s) => s.key.sessionId), [
      'cli-0',
      'cli-1',
      'cli-2',
      'cli-3',
      'cli-4',
    ]);
  });

  group('a native row is watched only on evidence it runs', () {
    // The owner's app on 2026-09-22: 26 watched with two panes open. 24 rows
    // sat at `unknown` — the status a row is left at when its pane dies — each
    // naming a pane that no longer existed, and all were watched for ever
    // because `unknown` is not an ending.
    Session lost(String id, {String? externalId}) => session(
      id: id,
      status: SessionStatus.unknown,
    ).copyWith(externalSessionId: externalId, paneId: 'gone-$id');

    test(
      'a row whose pane is gone, with nothing else, is not watched',
      () async {
        sessions.insert(lost('s1', externalId: 'cli-1'));

        expect(await settled(loader()), isEmpty);
      },
    );

    test('a row whose pane is live is watched', () async {
      sessions.insert(
        session(
          id: 's1',
          status: SessionStatus.running,
        ).copyWith(externalSessionId: 'cli-1', paneId: 'p1'),
      );
      livePanes.add('p1');

      expect((await settled(loader())).single.openId, 's1');
    });

    test('a row whose pane is open but not running is not watched', () async {
      sessions.insert(
        session(id: 's1').copyWith(externalSessionId: 'cli-1', paneId: 'p1'),
      );

      expect(await settled(loader()), isEmpty);
    });

    test('a row a hook has reported is watched without a pane', () async {
      sessions.insert(lost('s1', externalId: 'cli-1'));
      hook('cli-1');

      expect((await settled(loader())).single.key.sessionId, 'cli-1');
    });

    test('two live rows among 24 lost ones watch two', () async {
      for (var i = 0; i < 24; i++) {
        // Four of the owner's 24 never learned a CLI id.
        sessions.insert(lost('dead-$i', externalId: i < 20 ? 'old-$i' : null));
      }
      for (final id in ['live-a', 'live-b']) {
        sessions.insert(
          session(
            id: id,
            status: SessionStatus.running,
          ).copyWith(externalSessionId: 'cli-$id', paneId: 'pane-$id'),
        );
        livePanes.add('pane-$id');
      }

      final watched = await settled(loader());

      expect(watched.map((s) => s.openId).toSet(), {'live-a', 'live-b'});
    });

    test(
      'a row launched into an outside terminal is watched while new',
      () async {
        // No pane of ours, and no hook until the agent's first event.
        final clock = _MovableClock(testTime);
        sessions.insert(
          session(id: 's1', status: SessionStatus.unknown).copyWith(
            externalSessionId: 'cli-1',
            surface: SessionSurface.external,
          ),
        );
        final subject = loader(clock: clock);

        expect(await settled(subject), hasLength(1));

        clock.now = testTime.add(const Duration(hours: 1));
        expect(await settled(subject), isEmpty);
      },
    );

    test(
      'a row that lost its pane is watched while its transcript still moves',
      () async {
        final clock = _MovableClock(testTime);
        final path = transcript('native', age: const Duration(minutes: 1));
        sessions.insert(
          session(
            id: 's1',
            status: SessionStatus.running,
          ).copyWith(externalSessionId: 'cli-1', paneId: 'p1'),
        );
        livePanes.add('p1');
        // The registry answers only while it watches the row.
        String? resolved(String id) =>
            livePanes.contains('p1') && id == 's1' ? path : null;
        final subject = loader(clock: clock, transcriptPathFor: resolved);

        expect(await settled(subject), hasLength(1));

        livePanes.remove('p1');
        expect(
          await settled(subject),
          hasLength(1),
          reason: 'the transcript changed a minute ago',
        );

        clock.now = testTime.add(const Duration(hours: 2));
        expect(await settled(subject), isEmpty);
      },
    );

    test('a lost row the registry never resolved costs no stat', () async {
      sessions.insert(lost('s1', externalId: 'cli-1'));
      final tally = _Tally();
      final subject = loader(transcriptPathFor: (_) => null);

      await IOOverrides.runZoned(() async {
        subject.load();
        await subject.settle();
        subject.load();
      }, createFile: (path) => _CountingFile(path, tally));

      expect(tally.async + tally.sync, 0);
    });
  });

  for (final count in [100, 500]) {
    test('all $count live sessions are watched, not the first 60', () async {
      for (var i = 0; i < count; i++) {
        addImported(
          'i$i',
          externalId: 'cli-$i',
          filePath: transcript('t$i', age: const Duration(minutes: 1)),
          title: 'Session $i',
        );
      }

      final watched = await settled(loader());

      expect(watched, hasLength(count));
      expect(watched.map((s) => s.key.sessionId).toSet(), {
        for (var i = 0; i < count; i++) 'cli-$i',
      });
    });
  }

  test('every live native session is watched however many there are', () async {
    for (var i = 0; i < 200; i++) {
      sessions.insert(
        session(
          id: 's$i',
        ).copyWith(externalSessionId: 'cli-$i', paneId: 'pane-$i'),
      );
      livePanes.add('pane-$i');
    }

    final watched = await settled(loader());

    expect(watched, hasLength(200));
    expect(
      watched.any((s) => s.key.sessionId == 'cli-199'),
      isTrue,
      reason: 'the old cap kept the newest 60 and forgot the rest',
    );
  });
}

/// Counts what a `File` is asked to do, so a test can say whether a code path
/// stats the disk synchronously — which on the UI isolate is a blocked frame —
/// or asynchronously, which costs the isolate only a completion.
///
/// Answers from `FileStat`'s statics rather than by delegating to a real
/// `File`, because a delegate constructed inside the override zone would be
/// this class again.
class _CountingFile implements File {
  _CountingFile(this.path, this._tally);

  @override
  final String path;
  final _Tally _tally;

  @override
  bool existsSync() {
    _tally.sync++;
    return FileStat.statSync(path).type != FileSystemEntityType.notFound;
  }

  @override
  DateTime lastModifiedSync() {
    _tally.sync++;
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException('no such file', path);
    }
    return stat.modified;
  }

  @override
  Future<FileStat> stat() {
    _tally.async++;
    return FileStat.stat(path);
  }

  @override
  FileStat statSync() {
    _tally.sync++;
    return FileStat.statSync(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'the loader is not expected to call ${invocation.memberName}',
  );
}

class _Tally {
  int sync = 0;
  int async = 0;
}
