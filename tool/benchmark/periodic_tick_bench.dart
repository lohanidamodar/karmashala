import 'dart:async';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/util/clock.dart';
import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/imported_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/notifications/application/session_status_registry.dart';
import 'package:chitragupta/src/features/notifications/application/watched_session_loader.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../test/support/fixtures.dart';

/// Benchmark — NOT part of `flutter test`'s default run. Run it on demand:
///
///   flutter test tool/benchmark/periodic_tick_bench.dart
///
/// **What the app's periodic timers cost the UI isolate**, at the owner's real
/// workspace size (7 native + 107 imported sessions, counted off their live
/// database).
///
/// The lag being chased is periodic, not continuous, so the question is not
/// "what does a frame cost" but "what does a *tick* cost, and how often is the
/// expensive kind of tick paid". Three numbers, in the order they mattered:
///
/// * **wall time per status cycle** — what `WatchedSessionLoader.load()` costs
///   on the 1.2-second cycle, measured across two full cold-recheck windows.
///   The interesting statistic is not the median, it is the *max*: every cold
///   transcript is marked cold in the same cycle and given the same deadline,
///   so they all come due together. Fifty-nine free cycles, then one that
///   stats the entire workspace, once a minute, forever.
///
/// * **the store multiplier** — the same measurement is 17× cheaper here than
///   on the owner's machine, and the benchmark cannot show that on its own:
///   64 of their 107 transcripts live under `\\wsl.localhost\archlinux\...`,
///   where one `existsSync` + `lastModifiedSync` pair measures **1.19 ms**
///   against **0.07 ms** for the same pair on local NTFS. Point
///   `CHITRAGUPTA_BENCH_TRANSCRIPT_DIR` at a real store to measure it directly
///   rather than reading the multiplier off this comment.
///
/// * **sync versus async** — the same sweep, done with `File.stat()` instead of
///   `existsSync()`/`lastModifiedSync()`, costs the event loop nothing:
///   `dart:io`'s asynchronous file calls run on the IO thread pool and only
///   their completions come back to the isolate. This is the measurement the
///   fix rests on, so it is made rather than asserted.
void main() {
  /// The owner's workspace, as of the hunt.
  const importedCount = 107;
  const nativeCount = 7;

  /// How many imported transcripts have been written to in the last half hour.
  /// Kept small on purpose: the burst is the interesting cost, and it is paid
  /// by the *cold* ones.
  const warmCount = 4;

  late Directory temp;
  late AppDatabase db;
  late SessionDao sessions;
  late ImportedSessionDao imported;
  late AgentInstallationDao installations;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    sessions = SessionDao(db);
    imported = ImportedSessionDao(db);
    installations = AgentInstallationDao(db)..insert(agentInstallation());
    temp = Directory.systemTemp.createTempSync('periodic-tick');
    addTearDown(() {
      db.close();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  /// A transcript file [age] old, and the path to it.
  String transcript(String name, {required Duration age}) {
    final path = p.join(temp.path, '$name.jsonl');
    File(path)
      ..writeAsStringSync('{"type":"user"}\n')
      ..setLastModifiedSync(testTime.subtract(age));
    return path;
  }

  /// The owner's workspace: a handful of live native rows and a long tail of
  /// imported transcripts, nearly all of them cold.
  void fillWorkspace() {
    for (var i = 0; i < nativeCount; i++) {
      sessions.insert(
        session(id: 's$i').copyWith(externalSessionId: 'cli-native-$i'),
      );
    }
    for (var i = 0; i < importedCount; i++) {
      imported.insertIfAbsent(
        ImportedSession(
          id: 'i$i',
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'cli-$i',
          environmentId: 'windows',
          filePath: transcript(
            't$i',
            age: i < warmCount
                ? const Duration(minutes: 1)
                : const Duration(days: 3),
          ),
          storeHome: temp.path,
          isSubagent: false,
          preview: 'hello',
          title: 'Session $i',
          createdAt: testTime,
        ),
      );
    }
  }

  WatchedSessionLoader loaderOn(Clock clock) => WatchedSessionLoader(
    sessionDao: sessions,
    importedSessionDao: imported,
    installationDao: installations,
    hookReports: AgentHookReports(),
    clock: clock,
  );

  test('what one status cycle costs the UI isolate, minute by minute', () async {
    fillWorkspace();
    final clock = _MovableClock(testTime);
    final loader = loaderOn(clock);

    // Two full cold-recheck windows at the real cycle rate.
    const cycles = 100;
    final costs = <int>[];
    for (var i = 0; i < cycles; i++) {
      final sw = Stopwatch()..start();
      loader.load();
      // BASELINE: no async sampler yet.
      costs.add(sw.elapsedMicroseconds);
      clock.now = clock.now.add(kStatusCycleInterval);
    }

    final sorted = [...costs]..sort();
    final median = sorted[cycles ~/ 2];
    final bursts = costs.where((c) => c > median * 4 + 2000).length;
    String ms(int us) => '${(us / 1000).toStringAsFixed(2)}ms';
    // ignore: avoid_print
    print(
      'load() over $cycles cycles of ${kStatusCycleInterval.inMilliseconds}ms, '
      '${importedCount + nativeCount} sessions ($warmCount warm)\n'
      '  first   ${ms(costs.first)}  (nothing cached yet)\n'
      '  median  ${ms(median)}\n'
      '  p90     ${ms(sorted[(cycles * 0.9).floor()])}\n'
      '  max     ${ms(sorted.last)}\n'
      '  bursts  $bursts of $cycles cycles cost >4x the median',
    );
    expect(costs, hasLength(cycles));
  });

  test('which periodic tick actually stalls the event loop', () async {
    fillWorkspace();
    final paths = [for (final row in imported.getAll()) row.filePath];

    // A 1 ms ticker is the cheapest honest proxy for "can this isolate get back
    // to the frame pipeline": every gap longer than the interval is time the
    // event loop could not run, which on the UI isolate is a dropped frame.
    // Measured against an idle baseline, because the harness has noise of its
    // own and a number without a floor under it says nothing.
    Future<int> worstGapDuring(FutureOr<void> Function() work) async {
      var worst = 0;
      var since = Stopwatch()..start();
      final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final gap = since.elapsedMicroseconds;
        if (gap > worst) worst = gap;
        since = Stopwatch()..start();
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await work();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      ticker.cancel();
      return worst;
    }

    Future<int> best(FutureOr<void> Function() work) async {
      var lowest = 1 << 30;
      for (var i = 0; i < 3; i++) {
        final gap = await worstGapDuring(work);
        if (gap < lowest) lowest = gap;
      }
      return lowest;
    }

    final idle = await best(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    final syncStats = await best(() {
      for (final path in paths) {
        final file = File(path);
        if (file.existsSync()) file.lastModifiedSync();
      }
    });
    final asyncStats = await best(() async {
      for (final path in paths) {
        await File(path).stat();
      }
    });
    // The 2-minute delivery poll's cost, in the shape it actually takes: a
    // `gh` process per checkout, and the owner has 17 repositories. `dart
    // --version` stands in for `gh pr view` because the question is whether a
    // *spawn* blocks the isolate, not what GitHub answers.
    final spawns = await best(() async {
      for (var i = 0; i < 17; i++) {
        await Process.run(Platform.resolvedExecutable, ['--version']);
      }
    });

    String ms(int us) => '${(us / 1000).toStringAsFixed(2)}ms';
    // ignore: avoid_print
    print(
      'worst event-loop gap (best of 3 runs, ${paths.length} transcripts)\n'
      '  idle                      ${ms(idle)}\n'
      '  sync existsSync+mtime     ${ms(syncStats)}   <- WatchedSessionLoader\n'
      '  async File.stat()         ${ms(asyncStats)}\n'
      '  17 process spawns         ${ms(spawns)}   <- the delivery poll',
    );

    // The claim the fix rests on: the asynchronous form costs the event loop
    // what doing nothing costs it, and the synchronous one does not.
    expect(syncStats, greaterThan(asyncStats));
  });
}

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}
