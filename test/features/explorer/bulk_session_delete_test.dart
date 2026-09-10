import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/bulk_session_delete.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/data/notification_presenter.dart';
import 'package:karmashala/src/features/notifications/domain/notification_request.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// **Deleting a ticked set of sessions.**
///
/// One action, two halves, and the order between them is the whole safety
/// argument: the workspace rows go first and synchronously, because taking a
/// session out of the workspace is undone by re-importing it; the CLI store
/// purge runs behind them, because deleting an agent's own transcript is undone
/// by nothing.
///
/// The selection holds both kinds of row and each has to reach its own delete —
/// a native row's transcript is found by walking the CLI stores for its
/// conversation id, an imported row already carries its own file — and the
/// batch has to stay a batch: one walk of the stores for every native row in
/// the set, one index pass per store for the lot. Deleting them one at a time
/// is the quadratic thing the batched path was written to stop.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_bulk_'));
  tearDown(() => removeTempDirectory(tmp));

  String claudeHome() => p.join(tmp.path, '.claude');

  /// Where the transcript for conversation [externalId] lives on disk.
  String transcript(String externalId) =>
      p.join(claudeHome(), 'projects', '-demo', '$externalId.jsonl');

  void writeTranscript(String externalId) {
    File(transcript(externalId))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"user"}\n');
    File(p.join(claudeHome(), 'sessions', '$externalId.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'sessionId': externalId}));
  }

  late AppDatabase db;
  late _StoreDetection detection;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    detection = _StoreDetection([]);
  });
  tearDown(() => db.close());

  /// A native row, with a real transcript the store scan can find.
  void addNative(String id, {required String title}) {
    final externalId = 'ext-$id';
    writeTranscript(externalId);
    detection.sessions.add(
      DetectedSession(
        cli: AgentIds.claudeCode,
        sessionId: externalId,
        cwd: repository().path,
        filePath: transcript(externalId),
        storeHome: claudeHome(),
        title: title,
      ),
    );
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: title,
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: externalId,
      ),
    );
  }

  /// An imported row, which carries its own store file and needs no scan.
  void addImported(String id, {required String title}) {
    final externalId = 'cli-$id';
    writeTranscript(externalId);
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: id,
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: externalId,
        environmentId: 'windows',
        filePath: transcript(externalId),
        storeHome: claudeHome(),
        isSubagent: false,
        preview: title,
        title: title,
        createdAt: testTime,
      ),
    );
  }

  ({ProviderContainer container, CliSessionMutator mutator}) mount({
    CliSessionMutator? mutator,
    _RecordingPresenter? presenter,
  }) {
    final effective = mutator ?? CliSessionMutator();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        cliSessionMutatorProvider.overrideWithValue(effective),
        cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
        cliDetectionServiceProvider.overrideWithValue(detection),
        if (presenter != null)
          notificationPresenterProvider.overrideWithValue(presenter),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mutator: effective);
  }

  group('routing', () {
    test(
      'both kinds are selected together and each leaves by its own path',
      () async {
        addNative('n0', title: 'Native one');
        addNative('n1', title: 'Native two');
        addImported('i0', title: 'Imported one');
        final (:container, :mutator) = mount();
        final bulk = container.read(sessionBulkDeleteProvider);

        final targets = bulk.resolve(const ['n0', 'i0', 'n1']);
        expect(targets.natives.map((s) => s.id), ['n0', 'n1']);
        expect(targets.imported.map((s) => s.id), ['i0']);

        bulk.run(targets, deleteFromCli: true);

        // The rows are already gone, in the same turn the confirmation returned.
        expect(SessionDao(db).getById('n0'), isNull);
        expect(SessionDao(db).getById('n1'), isNull);
        expect(ImportedSessionDao(db).getById('i0'), isNull);

        await bulk.settled;
        for (final external in ['ext-n0', 'ext-n1', 'cli-i0']) {
          expect(
            File(transcript(external)).existsSync(),
            isFalse,
            reason: '$external should have been purged',
          );
        }
      },
    );

    test('an id that names nothing is dropped rather than carried', () {
      addNative('n0', title: 'Native one');
      final (:container, :mutator) = mount();

      final targets = container.read(sessionBulkDeleteProvider).resolve(const [
        'n0',
        'gone',
      ]);

      expect(targets.count, 1);
      expect(targets.titles, ['Native one']);
    });

    test(
      'deleting the open session clears what the right pane is showing',
      () async {
        addNative('n0', title: 'Native one');
        addImported('i0', title: 'Imported one');
        final (:container, :mutator) = mount();
        container.read(selectedSessionIdProvider.notifier).select('n0');
        container.read(selectedImportedSessionIdProvider.notifier).select('i0');
        final bulk = container.read(sessionBulkDeleteProvider);

        bulk.run(bulk.resolve(const ['n0', 'i0']), deleteFromCli: false);

        expect(container.read(selectedSessionIdProvider), isNull);
        expect(container.read(selectedImportedSessionIdProvider), isNull);
      },
    );

    test('the ticked set empties itself as the rows leave', () async {
      addNative('n0', title: 'Native one');
      addNative('n1', title: 'Native two');
      final (:container, :mutator) = mount();
      final selection = container.read(sessionSelectionProvider.notifier)
        ..enter()
        ..toggle('n0')
        ..toggle('n1');
      final bulk = container.read(sessionBulkDeleteProvider);

      bulk.run(bulk.resolve(const ['n0']), deleteFromCli: false);

      // Pruned by the membership signal the delete publishes — the same
      // mechanism that drops a row deleted from another window.
      expect(container.read(sessionSelectionProvider).ids, {'n1'});
      expect(selection.state.active, isTrue, reason: 'the mode stays on');
    });
  });

  group('the transcript box', () {
    test('unticked leaves every transcript on disk', () async {
      addNative('n0', title: 'Native one');
      addImported('i0', title: 'Imported one');
      final (:container, :mutator) = mount();
      final bulk = container.read(sessionBulkDeleteProvider);

      bulk.run(bulk.resolve(const ['n0', 'i0']), deleteFromCli: false);
      await bulk.settled;

      expect(SessionDao(db).getById('n0'), isNull);
      expect(ImportedSessionDao(db).getById('i0'), isNull);
      expect(File(transcript('ext-n0')).existsSync(), isTrue);
      expect(File(transcript('cli-i0')).existsSync(), isTrue);
      expect(bulk.pending, 0, reason: 'nothing is started to do nothing');
      expect(mutator.transcriptsDeleted, 0);
    });

    test(
      'ticked takes them, behind the rows rather than in front of them',
      () async {
        addNative('n0', title: 'Native one');
        addImported('i0', title: 'Imported one');
        final (:container, :mutator) = mount();
        final bulk = container.read(sessionBulkDeleteProvider);

        bulk.run(bulk.resolve(const ['n0', 'i0']), deleteFromCli: true);

        // The rows have gone and the files have not: the irreversible half is
        // still running. This is the assertion that fails if it is ever awaited
        // inline again.
        expect(SessionDao(db).getById('n0'), isNull);
        expect(bulk.pending, 1);
        expect(File(transcript('ext-n0')).existsSync(), isTrue);

        await bulk.settled;
        expect(File(transcript('ext-n0')).existsSync(), isFalse);
        expect(File(transcript('cli-i0')).existsSync(), isFalse);
        expect(bulk.pending, 0);
      },
    );

    test(
      'a native row whose conversation is not in any store is reported',
      () async {
        // Its transcript is still on disk under some name we cannot match, so
        // saying nothing would be the lie.
        addNative('n0', title: 'Native one');
        detection.sessions.clear();
        final presenter = _RecordingPresenter();
        final (:container, :mutator) = mount(presenter: presenter);
        final bulk = container.read(sessionBulkDeleteProvider);

        bulk.run(bulk.resolve(const ['n0']), deleteFromCli: true);
        await bulk.settled;

        expect(SessionDao(db).getById('n0'), isNull);
        final shown = presenter.shown.single;
        expect(shown.title, '1 session file was left behind');
        expect(shown.body, contains('Native one'));
      },
    );
  });

  group('a partial failure', () {
    test('does not abandon the rest, and names what was left behind', () async {
      addNative('n0', title: 'Native one');
      addNative('n1', title: 'Native two');
      addImported('i0', title: 'Imported one');
      addImported('i1', title: 'Imported two');
      final presenter = _RecordingPresenter();
      final (:container, :mutator) = mount(
        mutator: _RefusingMutator(const {'ext-n1'}),
        presenter: presenter,
      );
      final bulk = container.read(sessionBulkDeleteProvider);

      bulk.run(
        bulk.resolve(const ['n0', 'n1', 'i0', 'i1']),
        deleteFromCli: true,
      );

      // The rows all left the workspace regardless — that half never depended
      // on the store, and it is the half that can be undone.
      expect(SessionDao(db).getByRepository('r1'), isEmpty);
      expect(ImportedSessionDao(db).getByRepository('r1'), isEmpty);

      await bulk.settled;
      for (final external in ['ext-n0', 'cli-i0', 'cli-i1']) {
        expect(
          File(transcript(external)).existsSync(),
          isFalse,
          reason: 'one bad file must not take the batch with it ($external)',
        );
      }
      expect(File(transcript('ext-n1')).existsSync(), isTrue);

      final shown = presenter.shown.single;
      expect(shown.title, '1 session file was left behind');
      expect(shown.body, startsWith('4 sessions are out of the workspace'));
      expect(shown.body, contains('Native two'));
      expect(shown.body, contains('CLI store'));
    });

    test('three are named and the rest counted, as everywhere else', () async {
      for (var i = 0; i < 5; i++) {
        addImported('i$i', title: 'Imported $i');
      }
      final presenter = _RecordingPresenter();
      final (:container, :mutator) = mount(
        mutator: _RefusingMutator(const {
          'cli-i0',
          'cli-i1',
          'cli-i2',
          'cli-i3',
        }),
        presenter: presenter,
      );
      final bulk = container.read(sessionBulkDeleteProvider);

      bulk.run(
        bulk.resolve(const ['i0', 'i1', 'i2', 'i3', 'i4']),
        deleteFromCli: true,
      );
      await bulk.settled;

      final shown = presenter.shown.single;
      expect(shown.title, '4 session files were left behind');
      expect(shown.body, contains('+1 more'));
    });

    test('a clean delete says nothing at all', () async {
      addNative('n0', title: 'Native one');
      addImported('i0', title: 'Imported one');
      final presenter = _RecordingPresenter();
      final (:container, :mutator) = mount(presenter: presenter);
      final bulk = container.read(sessionBulkDeleteProvider);

      bulk.run(bulk.resolve(const ['n0', 'i0']), deleteFromCli: true);
      await bulk.settled;

      expect(presenter.shown, isEmpty);
    });
  });

  group('nothing outlives the task', () {
    test('a container disposed mid-purge is never read from', () async {
      addImported('i0', title: 'Imported one');
      final presenter = _RecordingPresenter();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          cliSessionMutatorProvider.overrideWithValue(
            _RefusingMutator(const {'cli-i0'}),
          ),
          cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
          cliDetectionServiceProvider.overrideWithValue(detection),
          notificationPresenterProvider.overrideWithValue(presenter),
        ],
      );
      final bulk = container.read(sessionBulkDeleteProvider);

      bulk.run(bulk.resolve(const ['i0']), deleteFromCli: true);
      expect(bulk.pending, 1);

      container.dispose();
      await bulk.settled;

      expect(bulk.pending, 0);
      expect(presenter.shown, isEmpty);
    });
  });
}

/// A detection service that answers from a fixed list, so a test never walks
/// the machine's own `~/.claude`.
class _StoreDetection implements CliDetectionService {
  _StoreDetection(this.sessions);

  final List<DetectedSession> sessions;

  /// How many times the whole store was walked — the number the batch exists to
  /// keep at one.
  int passes = 0;

  @override
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, ExecutionEnvironment> environmentsById,
  ) async {
    passes++;
    return [
      DetectedProject(
        canonicalKey: 'demo',
        displayPath: r'C:\src\demo\app',
        sessions: List.of(sessions),
        subagentSessions: const [],
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Refuses the named conversations and really deletes the rest, so a partial
/// failure is deterministic on every platform.
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
