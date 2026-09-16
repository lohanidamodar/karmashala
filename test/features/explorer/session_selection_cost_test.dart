import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/bulk_session_delete.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/temp_directory.dart';

/// **What selecting and bulk-deleting cost, counted.**
///
/// Counted, never timed — the house rule, and for the reason every other
/// `*_cost_test.dart` here gives: wall-clock over a few milliseconds fails
/// whenever the machine is busy, and the units that actually matter are
/// countable directly.
///
/// Two things are measured, and they are the two ways this feature could have
/// been slow:
///
/// 1. **Ticking a row.** The Explorer inflates one `ConsumerWidget` per visible
///    row and this panel is already on a hot path the app has had to fix twice.
///    A selection watched as a whole value would have rebuilt all thirty rows
///    to tick one; every reader instead selects the single fact it draws.
/// 2. **Deleting N of them.** The batched delete that landed for project
///    removal is what this rides on, and the point of it is that the store work
///    is per *store*, not per session: one walk of the CLI stores to identify
///    every native row, one index pass per store for the lot. The publish is
///    one for the whole set, because three bare listeners on the sessions
///    revision each do real work per bump.
void main() {
  group('ticking one row', () {
    /// A busy-but-ordinary project. Thirty cards is what fits a tall pane, and
    /// it is the number the brief names.
    const rows = 30;

    late AppDatabase db;

    setUp(() {
      db = AppDatabase.memory();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
      RepositoryDao(
        db,
      ).insert(repository(id: 'r1', name: 'hub', path: r'C:\hub'));
      AgentInstallationDao(db).insert(agentInstallation());
      for (var i = 0; i < rows; i++) {
        SessionDao(db).insert(
          Session(
            id: 'n$i',
            repositoryId: 'r1',
            agentInstallationId: 'a1',
            title: 'Session $i',
            useWorktree: false,
            status: SessionStatus.running,
            createdAt: testTime.add(Duration(minutes: i)),
            externalSessionId: 'ext-n$i',
          ),
        );
      }
    });
    tearDown(() => db.close());

    Future<ProviderContainer> pump(WidgetTester tester) async {
      // Tall enough that every one of the thirty cards is really inflated: a
      // sliver that never built a row cannot be seen to rebuild.
      tester.view.physicalSize = const Size(460, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
      return container;
    }

    /// A rebuilt card is a **new widget instance**, so identity is the counter:
    /// it needs no instrumentation inside the widgets under test and cannot be
    /// fooled by a card that rebuilt to the same pixels.
    List<int> identities(WidgetTester tester) => [
      for (final card in tester.widgetList<SessionCard>(
        find.byType(SessionCard),
      ))
        identityHashCode(card),
    ];

    int changed(List<int> before, List<int> after) {
      if (before.length != after.length) return after.length;
      var count = 0;
      for (var i = 0; i < before.length; i++) {
        if (before[i] != after[i]) count++;
      }
      return count;
    }

    testWidgets('rebuilds that row and nothing else on the tree', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(sessionSelectionProvider.notifier).enter();
      await tester.pumpAndSettle();

      final before = identities(tester);
      expect(before, hasLength(rows), reason: 'all $rows cards must be built');

      container.read(sessionSelectionProvider.notifier).toggle('n7');
      await tester.pump();

      final after = identities(tester);
      final moved = changed(before, after);
      // ignore: avoid_print
      print('SELECTION-COST tick cards=${before.length} rebuilt=$moved');
      expect(
        moved,
        1,
        reason:
            'one tick, one rebuilt row: every reader selects the single fact '
            'it draws, so the other $rows-1 rows compare a bool and stop',
      );
    });

    testWidgets('ticking a second row still moves only that row', (
      tester,
    ) async {
      final container = await pump(tester);
      final selection = container.read(sessionSelectionProvider.notifier)
        ..enter();
      await tester.pumpAndSettle();
      selection.toggle('n7');
      await tester.pump();

      final before = identities(tester);
      selection.toggle('n19');
      await tester.pump();

      // The cost of a tick must not grow with the size of the selection —
      // which it would if a row watched the set rather than its own membership.
      expect(changed(before, identities(tester)), 1);
    });

    testWidgets('entering the mode is the control: it does move every row', (
      tester,
    ) async {
      // Without this, "one rebuilt row" could just mean the counter cannot see
      // a rebuild. Turning the checkboxes on is a change to every row, and it
      // must show up as one.
      final container = await pump(tester);
      final before = identities(tester);

      container.read(sessionSelectionProvider.notifier).enter();
      await tester.pumpAndSettle();

      expect(changed(before, identities(tester)), before.length);
    });
  });

  group('deleting N sessions', () {
    /// One is the "did we make the small case worse" control; 33 is the largest
    /// project in the owner's own workspace, and the number the batched project
    /// delete was measured at.
    const scale = [1, 10, 33];

    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_bulkc_'));
    tearDown(() => removeTempDirectory(tmp));

    String claudeHome() => p.join(tmp.path, '.claude');
    String codexHome() => p.join(tmp.path, '.codex');

    final measured = <int, _Cost>{};

    for (final count in scale) {
      test('$count sessions', () async {
        final db = _CountingDatabase();
        addTearDown(db.close);
        ExecutionEnvironmentDao(db).upsert(windowsEnv());
        ProjectDao(db).insert(project());
        RepositoryDao(db).insert(repository());
        AgentInstallationDao(db).insert(agentInstallation());

        // Half native and half imported, half Claude and half Codex, so the
        // batch has to group two stores *and* resolve native rows out of a
        // store walk — the two things it could have done per session.
        final detected = <DetectedSession>[];
        final codexIndex = <String>[];
        final ids = <String>[];
        for (var i = 0; i < count; i++) {
          final claude = i.isEven;
          final external = 'x$i';
          final String file;
          if (claude) {
            file = p.join(claudeHome(), 'projects', '-demo', '$external.jsonl');
            File(file)
              ..createSync(recursive: true)
              ..writeAsStringSync('{"type":"user"}\n');
            File(p.join(claudeHome(), 'sessions', '$external.json'))
              ..createSync(recursive: true)
              ..writeAsStringSync(jsonEncode({'sessionId': external}));
          } else {
            file = p.join(codexHome(), 'sessions', 'rollout-$external.jsonl');
            File(file)
              ..createSync(recursive: true)
              ..writeAsStringSync('{}\n');
            codexIndex.add(
              jsonEncode({'id': external, 'thread_name': 'Session $i'}),
            );
          }
          final cli = claude ? AgentIds.claudeCode : AgentIds.codex;
          final home = claude ? claudeHome() : codexHome();
          if (i.isEven) {
            // Native: the app knows only the conversation id, so the store has
            // to be walked to find this file at all.
            ids.add('n$i');
            detected.add(
              DetectedSession(
                cli: cli,
                sessionId: external,
                cwd: repository().path,
                filePath: file,
                storeHome: home,
                title: 'Session $i',
              ),
            );
            SessionDao(db).insert(
              Session(
                id: 'n$i',
                repositoryId: 'r1',
                agentInstallationId: 'a1',
                title: 'Session $i',
                useWorktree: false,
                status: SessionStatus.completed,
                createdAt: testTime,
                externalSessionId: external,
              ),
            );
          } else {
            ids.add('s$i');
            ImportedSessionDao(db).insertIfAbsent(
              ImportedSession(
                id: 's$i',
                repositoryId: 'r1',
                cli: cli,
                externalId: external,
                environmentId: 'windows',
                filePath: file,
                storeHome: home,
                isSubagent: false,
                preview: 'Session $i',
                title: 'Session $i',
                createdAt: testTime,
              ),
            );
          }
        }
        File(p.join(codexHome(), 'session_index.jsonl'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            codexIndex.isEmpty ? '' : '${codexIndex.join('\n')}\n',
          );

        final mutator = CliSessionMutator();
        final detection = _CountingDetection(detected);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            clockProvider.overrideWithValue(FixedClock(testTime)),
            cliSessionMutatorProvider.overrideWithValue(mutator),
            cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
            cliDetectionServiceProvider.overrideWithValue(detection),
          ],
        );
        addTearDown(container.dispose);

        var publishes = 0;
        container.listen(sessionsRevisionProvider, (_, _) => publishes++);
        final bulk = container.read(sessionBulkDeleteProvider);
        final targets = bulk.resolve(ids);
        db.reset();

        bulk.run(targets, deleteFromCli: true);
        await bulk.settled;

        measured[count] = _Cost(
          storeScans: mutator.storeScans,
          indexEntriesRead: mutator.indexEntriesRead,
          detectionPasses: detection.passes,
          rowDeletes: db.rowDeletes,
          statements: db.statements,
          publishes: publishes,
        );

        // The work itself still happened.
        expect(mutator.transcriptsDeleted, count);
        expect(SessionDao(db).getByRepository('r1'), isEmpty);
        expect(ImportedSessionDao(db).getByRepository('r1'), isEmpty);
      });
    }

    test('the constant does not grow with the size of the selection', () {
      expect(
        measured.keys.toSet(),
        scale.toSet(),
        reason: 'every case above must have run',
      );
      // ignore: avoid_print
      print('bulk session delete cost: $measured');

      for (final count in scale) {
        final cost = measured[count]!;

        // One walk of the CLI stores for the whole selection, however many
        // native rows are in it. Per session this is the quadratic thing:
        // `deleteNative` walks every store to find one conversation.
        expect(
          cost.detectionPasses,
          lessThanOrEqualTo(1),
          reason: 'at $count: the stores are walked once, not once per row',
        );

        // One index pass per store touched — Claude's `sessions` listing and
        // Codex's `session_index.jsonl` — not one per session.
        expect(
          cost.storeScans,
          lessThanOrEqualTo(2),
          reason: 'at $count: one scan per store, no more',
        );

        // One signal fan-out for the whole act. Three bare listeners sit on
        // this counter and each does real work per bump.
        expect(
          cost.publishes,
          1,
          reason: 'at $count: exactly one publish for the whole selection',
        );

        // The rows themselves are linear in what was asked for, and nothing
        // else is: no read-back, no per-row transaction of its own.
        expect(
          cost.rowDeletes,
          count,
          reason: 'at $count: one DELETE per row deleted and not one more',
        );
      }

      // The 33-session case must not decode ~33× what the 1-session case does.
      expect(
        measured[33]!.indexEntriesRead,
        lessThan(measured[1]!.indexEntriesRead + 60),
        reason:
            'index records are decoded once per delete, not once per session '
            'per delete',
      );
    });
  });
}

class _Cost {
  const _Cost({
    required this.storeScans,
    required this.indexEntriesRead,
    required this.detectionPasses,
    required this.rowDeletes,
    required this.statements,
    required this.publishes,
  });

  final int storeScans;
  final int indexEntriesRead;
  final int detectionPasses;
  final int rowDeletes;
  final int statements;
  final int publishes;

  @override
  String toString() =>
      '(detections: $detectionPasses, scans: $storeScans, '
      'entries: $indexEntriesRead, rowDeletes: $rowDeletes, '
      'statements: $statements, publishes: $publishes)';
}

/// A detection service that answers from a fixed list and counts how often it
/// was asked — the number the batch exists to keep at one.
class _CountingDetection implements CliDetectionService {
  _CountingDetection(this.sessions);

  final List<DetectedSession> sessions;
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
