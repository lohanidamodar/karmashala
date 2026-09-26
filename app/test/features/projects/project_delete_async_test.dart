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
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala/src/features/projects/application/cli_store_purge.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// **Deleting a project does not hold the UI, and does not fail in silence.**
///
/// The owner asked for two things: get the work off the main thread, and say
/// something when part of it fails instead of swallowing it. The second half is
/// the one that was actually broken — `deleteProject` wrapped every session in
/// a bare `catch (_)`, so a transcript that could not be deleted was left on
/// disk and never mentioned again.
///
/// The order these tests pin is deliberate and is the safety argument for the
/// whole change: **the reversible half happens first.** Removing a project from
/// the workspace can be undone by re-importing the CLI stores; deleting an
/// agent's own transcript cannot. So the rows go immediately, where the user can
/// see it, and the irreversible half runs behind them and reports what it did.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_delx_'));
  tearDown(() => removeTempDirectory(tmp));

  String claudeHome() => p.join(tmp.path, '.claude');

  /// A project of [count] Claude sessions, each with a real transcript on disk.
  AppDatabase seed(int count, {String projectId = 'p1'}) {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: projectId));
    RepositoryDao(db).insert(repository(projectId: projectId));
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < count; i++) {
      final id = 'x$i';
      final file = p.join(claudeHome(), 'projects', '-demo', '$id.jsonl');
      File(file)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"type":"user"}\n');
      File(p.join(claudeHome(), 'sessions', '$id.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'sessionId': id}));
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 's$i',
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: id,
          environmentId: 'windows',
          filePath: file,
          storeHome: claudeHome(),
          isSubagent: false,
          preview: 'Session $i',
          title: 'Session $i',
          createdAt: testTime,
        ),
      );
    }
    return db;
  }

  ProviderContainer mount(
    AppDatabase db, {
    CliSessionMutator? mutator,
    _RecordingPresenter? presenter,
    bool autoDispose = true,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        cliSessionMutatorProvider.overrideWithValue(
          mutator ?? CliSessionMutator(),
        ),
        if (presenter != null)
          notificationPresenterProvider.overrideWithValue(presenter),
      ],
    );
    if (autoDispose) addTearDown(container.dispose);
    return container;
  }

  bool transcriptsRemain(int count) => List.generate(
    count,
    (i) => File(p.join(claudeHome(), 'projects', '-demo', 'x$i.jsonl')),
  ).any((f) => f.existsSync());

  group('the UI is not held while the store is purged', () {
    test('the project is gone before a single transcript is', () async {
      final db = seed(8);
      addTearDown(db.close);
      final container = mount(db);
      final runner = container.read(cliStorePurgeRunnerProvider);

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);

      // The caller's future is already complete, and the list it reads has
      // already been refreshed — no frame is waiting on the filesystem.
      expect(container.read(projectsControllerProvider), isEmpty);
      expect(ProjectDao(db).getById('p1'), isNull);
      expect(ImportedSessionDao(db).getByRepository('r1'), isEmpty);
      // …and the store work has genuinely not finished yet. This is the
      // assertion that would fail if the purge were awaited inline again.
      expect(runner.pending, 1);
      expect(
        transcriptsRemain(8),
        isTrue,
        reason: 'the purge has not run yet — it is behind the UI',
      );

      await runner.settled;
      expect(transcriptsRemain(8), isFalse);
      expect(runner.pending, 0);
    });

    test('nothing is started when the store is not being touched', () async {
      final db = seed(3);
      addTearDown(db.close);
      final container = mount(db);

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1');

      expect(container.read(cliStorePurgeRunnerProvider).pending, 0);
      expect(
        transcriptsRemain(3),
        isTrue,
        reason: 'unticked means the files on disk are left alone',
      );
    });
  });

  group('a session that cannot be deleted', () {
    test('does not abandon the rest, and is named in a notification', () async {
      final db = seed(5);
      addTearDown(db.close);
      final presenter = _RecordingPresenter();
      final container = mount(
        db,
        mutator: _RefusingMutator(const {'x2'}),
        presenter: presenter,
      );

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);
      await container.read(cliStorePurgeRunnerProvider).settled;

      // Every other transcript went. One bad file used to be swallowed by a
      // bare `catch (_)`; it must not take the batch with it either.
      for (final i in [0, 1, 3, 4]) {
        expect(
          File(
            p.join(claudeHome(), 'projects', '-demo', 'x$i.jsonl'),
          ).existsSync(),
          isFalse,
          reason: 'session $i should have been deleted',
        );
      }
      expect(
        File(
          p.join(claudeHome(), 'projects', '-demo', 'x2.jsonl'),
        ).existsSync(),
        isTrue,
      );

      // And the user is told, once, in words that name what is still on disk.
      final shown = presenter.shown.single;
      expect(shown.title, '1 session file was left behind');
      expect(shown.body, contains('Session 2'));
      expect(shown.body, contains('Demo'));
      expect(shown.body, contains('CLI store'));
    });

    test(
      'the workspace is still coherent: the project and its rows are gone',
      () async {
        final db = seed(4);
        addTearDown(db.close);
        final presenter = _RecordingPresenter();
        final container = mount(
          db,
          mutator: _RefusingMutator(const {'x0', 'x1', 'x2', 'x3'}),
          presenter: presenter,
        );

        await container
            .read(projectsControllerProvider.notifier)
            .deleteProject('p1', deleteCliSessions: true);
        await container.read(cliStorePurgeRunnerProvider).settled;

        // Not one transcript could be removed, and the workspace still lost the
        // project cleanly — no half-deleted project, and nothing silent.
        expect(ProjectDao(db).getById('p1'), isNull);
        expect(RepositoryDao(db).getByProject('p1'), isEmpty);
        expect(ImportedSessionDao(db).getByRepository('r1'), isEmpty);
        expect(container.read(projectsControllerProvider), isEmpty);
        expect(transcriptsRemain(4), isTrue);

        final shown = presenter.shown.single;
        expect(shown.title, '4 session files were left behind');
        // Three named, then a count — the app's existing coalescing wording.
        expect(shown.body, contains('+1 more'));
      },
    );

    test('a delete that loses nothing says nothing', () async {
      final db = seed(3);
      addTearDown(db.close);
      final presenter = _RecordingPresenter();
      final container = mount(db, presenter: presenter);

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);
      await container.read(cliStorePurgeRunnerProvider).settled;

      expect(presenter.shown, isEmpty);
    });
  });

  group('selection', () {
    test('deleting the selected project clears the selection', () async {
      final db = seed(2);
      addTearDown(db.close);
      SessionDao(db).insert(session(id: 'n1'));
      final container = mount(db);
      container.read(selectedProjectIdProvider.notifier).select('p1');
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      container.read(selectedSessionIdProvider.notifier).select('n1');
      container.read(selectedImportedSessionIdProvider.notifier).select('s0');

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);

      expect(container.read(selectedProjectIdProvider), isNull);
      expect(container.read(selectedRepositoryIdProvider), isNull);
      // Both session selections went too. They used to be cleared only as a
      // side effect of the per-session delete, so removing a project *without*
      // "delete session files" left the app selecting a row the cascade had
      // taken.
      expect(container.read(selectedSessionIdProvider), isNull);
      expect(container.read(selectedImportedSessionIdProvider), isNull);
    });

    test('a selection pointing elsewhere is left alone', () async {
      final db = seed(1);
      addTearDown(db.close);
      ProjectDao(db).insert(project(id: 'p2', name: 'Other'));
      RepositoryDao(db).insert(repository(id: 'r2', projectId: 'p2'));
      final container = mount(db);
      container.read(selectedProjectIdProvider.notifier).select('p2');
      container.read(selectedRepositoryIdProvider.notifier).select('r2');

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);

      expect(container.read(selectedProjectIdProvider), 'p2');
      expect(container.read(selectedRepositoryIdProvider), 'r2');
    });
  });

  group('nothing outlives the task', () {
    test('a container disposed mid-purge is never read from', () async {
      final db = seed(4);
      addTearDown(db.close);
      final presenter = _RecordingPresenter();
      final container = mount(
        db,
        mutator: _RefusingMutator(const {'x0'}),
        presenter: presenter,
        autoDispose: false,
      );
      final runner = container.read(cliStorePurgeRunnerProvider);

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);
      expect(runner.pending, 1);

      // The window closes while the purge is still running.
      container.dispose();
      await runner.settled;

      // No `Bad state: tried to read a disposed provider`, and nothing was
      // reported into a container that has gone.
      expect(runner.pending, 0);
      expect(presenter.shown, isEmpty);
    });

    test('the runner holds nothing once it has settled', () async {
      final db = seed(6);
      addTearDown(db.close);
      final container = mount(db);
      final runner = container.read(cliStorePurgeRunnerProvider);

      await container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true);
      await runner.settled;

      expect(runner.pending, 0);
      // A second wait is instant and adds nothing: no timer is rescheduling.
      await runner.settled;
      expect(runner.pending, 0);
    });
  });

  group('the batch keeps going after a real filesystem refusal', () {
    test(
      'one locked transcript, the rest deleted, the index still pruned',
      () async {
        final db = seed(4);
        addTearDown(db.close);
        final locked = File(
          p.join(claudeHome(), 'projects', '-demo', 'x1.jsonl'),
        );
        // Windows refuses to delete a file with an open handle; POSIX allows it.
        // Either outcome proves the claim under test — the *other* three go, and
        // the index is pruned in one pass regardless.
        final handle = locked.openSync(mode: FileMode.append);
        addTearDown(() {
          handle.closeSync();
          if (locked.existsSync()) locked.deleteSync();
        });

        final mutator = CliSessionMutator();
        final sessions = ImportedSessionDao(db).getByRepository('r1');
        final report = await mutator.deleteAll([
          for (final s in sessions)
            DetectedSession(
              cli: s.cli,
              sessionId: s.externalId,
              cwd: repository().path,
              filePath: s.filePath,
              storeHome: s.storeHome,
              title: s.title,
            ),
        ]);

        for (final i in [0, 2, 3]) {
          expect(
            File(
              p.join(claudeHome(), 'projects', '-demo', 'x$i.jsonl'),
            ).existsSync(),
            isFalse,
            reason: 'session $i is not the locked one',
          );
        }
        expect(
          mutator.storeScans,
          1,
          reason: 'one listing for the whole batch',
        );
        // The resume index lost every entry the batch actually removed.
        final indexDir = Directory(p.join(claudeHome(), 'sessions'));
        final remaining = indexDir.listSync().map((e) => p.basename(e.path));
        expect(remaining, isNot(contains('x0.json')));
        expect(remaining, isNot(contains('x3.json')));
        // Whichever way the platform went, the report is honest about it.
        expect(
          report.deleted + report.failures.length,
          4,
          reason:
              'every session is accounted for, as deleted or as left behind',
        );
      },
    );
  });
}

/// A mutator that refuses the named sessions and really deletes the rest, so a
/// partial failure is deterministic on every platform.
class _RefusingMutator extends CliSessionMutator {
  _RefusingMutator(this.refuse);

  final Set<String> refuse;

  @override
  Future<CliDeleteReport> deleteAll(Iterable<DetectedSession> sessions) async {
    final refused = sessions.where((s) => refuse.contains(s.sessionId));
    final report = await super.deleteAll(
      sessions.where((s) => !refuse.contains(s.sessionId)),
    );
    return CliDeleteReport(
      deleted: report.deleted,
      failures: [
        ...report.failures,
        for (final s in refused)
          CliDeleteFailure(
            label: s.displayTitle,
            error: const FileSystemException('in use by another process'),
          ),
      ],
    );
  }
}

class _RecordingPresenter implements NotificationPresenter {
  final List<NotificationRequest> shown = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> show(NotificationRequest request) async => shown.add(request);

  @override
  void dispose() {}
}
