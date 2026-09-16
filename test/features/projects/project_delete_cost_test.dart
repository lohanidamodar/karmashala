import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/application/cli_store_purge.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// **What deleting a project costs, counted.**
///
/// The owner's complaint was that deleting sessions or a whole project hammers
/// the main thread. It did, and the reason was a per-session constant that had
/// nothing to do with the session being deleted:
///
/// * `CliSessionMutator.delete` walked the **whole** store index once per
///   session — Claude by listing `~/.claude/sessions` and decoding every entry
///   in it, Codex by reading, decoding and rewriting the entire
///   `session_index.jsonl`. At N sessions and an index of M records that is
///   N×M reads and N full rewrites for N deletions.
/// * every session got its own sqlite `DELETE`, in its own implicit
///   transaction — and every one of those rows was about to go anyway, because
///   `projects → repositories → imported_sessions` cascades.
/// * every session got its own `SessionChange` publish, so every watcher of the
///   session list woke N times for one user action. `session_signal_cost_test`
///   already measured what one such fan-out costs.
///
/// Counted, never timed, for the reason every other `*_cost_test.dart` in this
/// repo gives: wall-clock over a few milliseconds fails whenever the machine is
/// busy, and the units that actually matter here are countable directly.
void main() {
  /// Where the curve is read. One session is the "did we make the small case
  /// worse" control; 33 is the largest project in the owner's own workspace.
  const scale = [1, 10, 33];

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_del_'));
  tearDown(() => removeTempDirectory(tmp));

  String claudeHome() => p.join(tmp.path, '.claude');
  String codexHome() => p.join(tmp.path, '.codex');

  /// A workspace of [count] imported sessions in one project, half Claude and
  /// half Codex, each with a real transcript and a real index entry — so the
  /// store work being counted is the work the app really does.
  _CountingDatabase seed(int count) {
    final db = _CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());

    final codexIndex = <String>[];
    for (var i = 0; i < count; i++) {
      final claude = i.isEven;
      final id = 'x$i';
      final String file;
      if (claude) {
        file = p.join(claudeHome(), 'projects', '-demo', '$id.jsonl');
        File(file)
          ..createSync(recursive: true)
          ..writeAsStringSync('{"type":"user","cwd":"/demo"}\n');
        File(p.join(claudeHome(), 'sessions', '$id.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'sessionId': id}));
      } else {
        file = p.join(codexHome(), 'sessions', 'rollout-$id.jsonl');
        File(file)
          ..createSync(recursive: true)
          ..writeAsStringSync('{}\n');
        codexIndex.add(jsonEncode({'id': id, 'thread_name': 'Session $i'}));
      }
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 's$i',
          repositoryId: 'r1',
          cli: claude ? AgentIds.claudeCode : AgentIds.codex,
          externalId: id,
          environmentId: 'windows',
          filePath: file,
          storeHome: claude ? claudeHome() : codexHome(),
          isSubagent: false,
          preview: 'Session $i',
          createdAt: testTime,
        ),
      );
    }
    File(p.join(codexHome(), 'session_index.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        codexIndex.isEmpty ? '' : '${codexIndex.join('\n')}\n',
      );
    return db;
  }

  ({ProviderContainer container, CliSessionMutator mutator}) mount(
    _CountingDatabase db,
  ) {
    final mutator = CliSessionMutator();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        cliSessionMutatorProvider.overrideWithValue(mutator),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mutator: mutator);
  }

  group('deleting a project of N sessions', () {
    final measured = <int, _Cost>{};

    for (final count in scale) {
      test('$count sessions', () async {
        final db = seed(count);
        addTearDown(db.close);
        final (:container, :mutator) = mount(db);

        var publishes = 0;
        container.listen(sessionsRevisionProvider, (_, _) => publishes++);
        // Force the projects controller to exist before the measurement so its
        // own first read is not counted as delete cost.
        container.read(projectsControllerProvider);
        db.reset();

        await container
            .read(projectsControllerProvider.notifier)
            .deleteProject('p1', deleteCliSessions: true);
        await container.read(cliStorePurgeRunnerProvider).settled;

        measured[count] = _Cost(
          storeScans: mutator.storeScans,
          indexEntriesRead: mutator.indexEntriesRead,
          indexWrites: mutator.indexWrites,
          rowDeletes: db.rowDeletes,
          publishes: publishes,
        );

        // The work itself still happened: every transcript is gone.
        expect(mutator.transcriptsDeleted, count);
        expect(ImportedSessionDao(db).getByRepository('r1'), isEmpty);
        expect(ProjectDao(db).getById('p1'), isNull);
      });
    }

    test('the constant does not grow with the number of sessions', () {
      expect(
        measured.keys.toSet(),
        scale.toSet(),
        reason: 'every case above must have run',
      );
      // ignore: avoid_print
      print('project delete cost: $measured');

      // One walk of each store's index, however many sessions are being
      // removed — not one per session.
      for (final count in scale) {
        expect(
          measured[count]!.storeScans,
          lessThanOrEqualTo(2),
          reason: 'at $count sessions: one scan per store touched, no more',
        );
      }

      // One publish for the whole delete. Every watcher of the session list
      // wakes once, not once per session.
      for (final count in scale) {
        expect(
          measured[count]!.publishes,
          1,
          reason: 'at $count sessions: exactly one signal fan-out',
        );
      }

      // The cascade already removes every session row, so the delete issues no
      // per-session `DELETE` of its own.
      for (final count in scale) {
        expect(
          measured[count]!.rowDeletes,
          lessThanOrEqualTo(2),
          reason: 'at $count sessions: the project row, and the cascade',
        );
      }

      // Index records are read once each, not once per session: the 33-session
      // case must not read ~17× what the 1-session case does.
      expect(
        measured[33]!.indexEntriesRead,
        lessThan(measured[1]!.indexEntriesRead + 60),
        reason: 'index entries are decoded once per delete, not once per '
            'session per delete',
      );
    });
  });
}

class _Cost {
  const _Cost({
    required this.storeScans,
    required this.indexEntriesRead,
    required this.indexWrites,
    required this.rowDeletes,
    required this.publishes,
  });

  final int storeScans;
  final int indexEntriesRead;
  final int indexWrites;
  final int rowDeletes;
  final int publishes;

  @override
  String toString() =>
      '(scans: $storeScans, entries: $indexEntriesRead, '
      'indexWrites: $indexWrites, rowDeletes: $rowDeletes, '
      'publishes: $publishes)';
}

/// Counts the statements a delete issues. `package:sqlite3` is synchronous, so
/// each one of these runs on the UI isolate inside the frame.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int rowDeletes = 0;
  int statements = 0;

  void reset() {
    rowDeletes = 0;
    statements = 0;
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements++;
    if (sql.trimLeft().toUpperCase().startsWith('DELETE')) rowDeletes++;
    super.execute(sql, params);
  }
}
